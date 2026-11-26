import Darwin
import Foundation

private enum TestError: Error { case failed(String) }

/// Runs the real install and uninstall scripts through AppleScript, without administrator privileges and
/// against a temporary folder whose path has spaces and an apostrophe.
@main
enum SudoInstallScriptTests {
	static var checks = 0
	static func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
		guard try condition() else { throw TestError.failed(name) }
		checks += 1
		print("PASS \(name)")
	}

	static func run(_ shellScript: String) throws -> Int {
		let source = SudoInstallScript.appleScript(shellScript, administrator: false)
		guard let script = NSAppleScript(source: source) else { throw TestError.failed("compile AppleScript") }
		var failure: NSDictionary?
		script.executeAndReturnError(&failure)
		guard let failure else { return 0 }
		guard let code = failure[NSAppleScript.errorNumber] as? Int, code > 0 else {
			throw TestError.failed("AppleScript failed: \(failure)")
		}
		return code
	}

	static func main() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent("Gaze sudo 'test' \(UUID().uuidString)").path
		defer { try? fm.removeItem(atPath: root) }
		let pamDir = root + "/etc/pam.d"
		try fm.createDirectory(atPath: pamDir, withIntermediateDirectories: true)
		let source = root + "/Gaze copy.app/Contents/Resources/pam_gaze.so"
		try fm.createDirectory(atPath: (source as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
		try Data("module".utf8).write(to: URL(fileURLWithPath: source))
		var paths = SudoInstallScript.Paths()
		paths.moduleFolder = root + "/Library/Security/Gaze"
		paths.sudoLocalPath = pamDir + "/sudo_local"
		paths.sudoLocalTemplate = pamDir + "/sudo_local.template"
		paths.setRootOwner = false
		// An existing sudo_local, read-only like the system's, with an old-style Gaze line.
		let otherRules = "auth       sufficient     pam_tid.so\n# Keep this comment about pam_gaze.so\n"
		let existing = "# Added by Gaze. Remove this line.\nauth       sufficient     /usr/local/lib/pam/pam_gaze.so\n" + otherRules
		try existing.write(toFile: paths.sudoLocalPath, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: paths.sudoLocalPath)
		let requirement = #"identifier "com.gazeunlock.Gaze" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: a@b.c (Y6LG3Q6HV4)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"#

		// Model macOS denying creation of the temporary PAM policy, while leaving
		// the original policy readable and the module destination writable.
		try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pamDir)
		defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pamDir) }
		try expect(try run(SudoInstallScript.install(source: source, requirement: requirement, paths: paths)) == SudoInstallScript.pamWriteDenied,
			"AppleScript reports a PAM write denial for the Terminal fallback")
		try expect(!fm.fileExists(atPath: paths.moduleFolder), "write denial leaves no partially installed module")
		try expect(try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8) == existing,
			"write denial preserves the original PAM policy")
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pamDir)

		try expect(try run(SudoInstallScript.install(source: source, requirement: requirement, paths: paths)) == 0,
			"install script succeeds")
		let local = try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8)
		try expect(SudoInstallScript.routesThroughGaze(local), "auth line present")
		try expect(local.hasPrefix(SudoInstallScript.authLine + "\n"), "auth line first")
		try expect(local == SudoInstallScript.authLine + "\n" + otherRules,
			"install replaces the legacy rule and preserves unrelated rules and comments")
		try expect(try String(contentsOfFile: paths.requirementPath, encoding: .utf8) == requirement + "\n",
			"requirement written verbatim")
		try expect(fm.contentsEqual(atPath: source, andPath: paths.modulePath), "module copied")

		// The pasted command runs the same script, including quotes in the source path and requirement.
		let sudoPrefix = "/usr/bin/sudo -k "
		let terminal = SudoInstallScript.terminalCommand(SudoInstallScript.install(source: source, requirement: requirement, paths: paths))
		try expect(terminal.hasPrefix(sudoPrefix), "Terminal requests fresh administrator authorization")
		try expect(try run(String(terminal.dropFirst(sudoPrefix.count))) == 0, "Terminal script can reinstall over read-only files")
		try expect(try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8) == local, "reinstall keeps a single Gaze rule")

		// Deny the final rename while allowing files to be staged in PAM's directory.
		try expect(chflags(paths.sudoLocalPath, UInt32(UF_IMMUTABLE)) == 0, "make the test policy immutable")
		defer { _ = chflags(paths.sudoLocalPath, 0) }
		try expect(try run(SudoInstallScript.install(source: source, requirement: "replacement", paths: paths)) == SudoInstallScript.pamWriteDenied,
			"a denied final policy replacement reports a PAM write denial")
		try expect(try String(contentsOfFile: paths.requirementPath, encoding: .utf8) == requirement + "\n",
			"a denied final policy replacement restores the previous listener requirement")
		try expect(chflags(paths.sudoLocalPath, 0) == 0, "make the test policy replaceable again")

		try expect(try run(SudoInstallScript.uninstall(paths: paths)) == 0, "uninstall script succeeds")
		let after = try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8)
		try expect(after == otherRules, "uninstall keeps unrelated rules and comments")
		try expect(!fm.fileExists(atPath: paths.modulePath) && !fm.fileExists(atPath: paths.requirementPath),
			"uninstall removes module and requirement")
		try fm.removeItem(atPath: paths.sudoLocalPath)
		try otherRules.write(toFile: paths.sudoLocalTemplate, atomically: true, encoding: .utf8)
		try expect(try run(SudoInstallScript.install(source: source, requirement: requirement, paths: paths)) == 0,
			"install succeeds without an existing sudo_local")
		try expect(try String(contentsOfFile: paths.sudoLocalPath, encoding: .utf8) == SudoInstallScript.authLine + "\n" + otherRules,
			"the first install keeps the template rules")

		try expect(SudoInstallScript.routesThroughGaze("auth\tsufficient   /Library/Security/Gaze/pam_gaze.so\n"),
			"spacing-insensitive match")
		try expect(SudoInstallScript.routesThroughGaze(existing, modulePath: SudoInstallScript.legacyModulePath),
			"existing installations still recognized")
		try expect(!SudoInstallScript.routesThroughGaze("#auth sufficient /Library/Security/Gaze/pam_gaze.so\n"),
			"commented line ignored")
		print("\(checks) checks passed")
	}
}
