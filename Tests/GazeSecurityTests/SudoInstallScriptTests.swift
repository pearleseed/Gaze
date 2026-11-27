import Darwin
import Foundation
import GazeSecurity
import Testing

@Suite("Sudo PAM Install & Uninstall Scripts")
struct SudoInstallScriptTests {
	private func runAppleScriptShell(_ shellScript: String) throws -> Int {
		let source = SudoInstallScript.appleScript(shellScript, administrator: false)
		let script = try #require(NSAppleScript(source: source))
		var failure: NSDictionary?
		script.executeAndReturnError(&failure)
		guard let failure else { return 0 }
		let code = try #require(failure[NSAppleScript.errorNumber] as? Int)
		#expect(code > 0, "AppleScript error was not a shell exit code: \(failure)")
		return code
	}

	@Test func installUninstallRollbackAndRoutesThroughGaze() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent("Gaze sudo 'test' \(UUID().uuidString)").path
		defer { try? fm.removeItem(atPath: root) }

		let pamDir = root + "/etc/pam.d"
		try fm.createDirectory(atPath: pamDir, withIntermediateDirectories: true)
		let source = root + "/Gaze copy.app/Contents/Resources/pam_gaze.so"
		try fm.createDirectory(
			atPath: (source as NSString).deletingLastPathComponent,
			withIntermediateDirectories: true
		)
		try Data("module".utf8).write(to: URL(fileURLWithPath: source))

		var paths = SudoInstallScript.Paths()
		paths.moduleFolder = root + "/Library/Security/Gaze"
		paths.sudoLocalPath = pamDir + "/sudo_local"
		paths.sudoLocalTemplate = pamDir + "/sudo_local.template"
		paths.setRootOwner = false

		let otherRules = "auth       sufficient     pam_tid.so\n# Keep this comment about pam_gaze.so\n"
		let existing =
			"# Added by Gaze. Remove this line.\nauth       sufficient     /usr/local/lib/pam/pam_gaze.so\n"
			+ otherRules
		try existing.write(toFile: paths.sudoLocalPath, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: paths.sudoLocalPath)

		let requirement =
			#"identifier "com.pearleseed.Gaze" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: a@b.c (Y6LG3Q6HV4)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"#

		// Model macOS denying temporary PAM policy creation.
		try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pamDir)
		defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pamDir) }
		#expect(
			try runAppleScriptShell(
				SudoInstallScript.install(source: source, requirement: requirement, paths: paths)
			) == SudoInstallScript.pamWriteDenied
		)
		#expect(!fm.fileExists(atPath: paths.moduleFolder))
		#expect(try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8) == existing)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pamDir)

		// Install over legacy rule while preserving unrelated rules & comments.
		#expect(
			try runAppleScriptShell(
				SudoInstallScript.install(source: source, requirement: requirement, paths: paths)
			) == 0
		)
		let local = try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8)
		#expect(SudoInstallScript.routesThroughGaze(local))
		#expect(local.hasPrefix(SudoInstallScript.authLine + "\n"))
		#expect(local == SudoInstallScript.authLine + "\n" + otherRules)
		#expect(try String(contentsOfFile: paths.requirementPath, encoding: .utf8) == requirement + "\n")
		#expect(fm.contentsEqual(atPath: source, andPath: paths.modulePath))

		// Terminal fallback command runs the same script cleanly.
		let sudoPrefix = "/usr/bin/sudo -k "
		let terminal = SudoInstallScript.terminalCommand(
			SudoInstallScript.install(source: source, requirement: requirement, paths: paths)
		)
		#expect(terminal.hasPrefix(sudoPrefix))
		#expect(try runAppleScriptShell(String(terminal.dropFirst(sudoPrefix.count))) == 0)
		#expect(try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8) == local)

		// Deny final policy replacement via UF_IMMUTABLE and verify module & requirement rollback.
		#expect(chflags(paths.sudoLocalPath, UInt32(UF_IMMUTABLE)) == 0)
		defer { _ = chflags(paths.sudoLocalPath, 0) }
		#expect(
			try runAppleScriptShell(
				SudoInstallScript.install(source: source, requirement: "replacement", paths: paths)
			) == SudoInstallScript.pamWriteDenied
		)
		#expect(try String(contentsOfFile: paths.requirementPath, encoding: .utf8) == requirement + "\n")
		#expect(chflags(paths.sudoLocalPath, 0) == 0)

		// Uninstall preserves unrelated rules and removes module and requirement.
		#expect(try runAppleScriptShell(SudoInstallScript.uninstall(paths: paths)) == 0)
		let after = try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8)
		#expect(after == otherRules)
		#expect(!fm.fileExists(atPath: paths.modulePath) && !fm.fileExists(atPath: paths.requirementPath))

		// First install from sudo_local.template keeps template rules.
		try fm.removeItem(atPath: paths.sudoLocalPath)
		try otherRules.write(toFile: paths.sudoLocalTemplate, atomically: true, encoding: .utf8)
		#expect(
			try runAppleScriptShell(
				SudoInstallScript.install(source: source, requirement: requirement, paths: paths)
			) == 0
		)
		#expect(
			try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8)
				== SudoInstallScript.authLine + "\n" + otherRules
		)

		#expect(SudoInstallScript.routesThroughGaze("auth\tsufficient   /Library/Security/Gaze/pam_gaze.so\n"))
		#expect(SudoInstallScript.routesThroughGaze(existing, modulePath: SudoInstallScript.legacyModulePath))
		#expect(!SudoInstallScript.routesThroughGaze("#auth sufficient /Library/Security/Gaze/pam_gaze.so\n"))
	}
}
