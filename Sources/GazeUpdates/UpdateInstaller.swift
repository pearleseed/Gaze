import AppKit
import CryptoKit
import Foundation
import GazeCore
import Observation
import Security
import Synchronization
import os

/// Downloads a release DMG, verifies it and swaps it in over the running app.
///
/// Same bundle id and signing policy, so UserDefaults, keychain and TCC carry
/// over with no migration. The swap and relaunch run in a detached helper after
/// this process exits, so a half-written bundle can never be launched.
@Observable
@MainActor
package final class UpdateInstaller {

	package enum State: Equatable, Sendable {
		case idle
		case downloading(fraction: Double)
		case installing
		case failed(String)
	}

	package struct Swap: Sendable {
		package let scriptPath: String

		package init(scriptPath: String) {
			self.scriptPath = scriptPath
		}
	}

	package enum CodeSigningMode: Equatable, Sendable {
		case teamSigned
		case adHoc

		package nonisolated static func resolve(teamIdentifier: String?, flags: UInt32) -> Self? {
			if let teamIdentifier, !teamIdentifier.isEmpty {
				return .teamSigned
			}
			if (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0 {
				return .adHoc
			}
			return nil
		}
	}

	package enum CodeRequirementPolicy {
		case runningProcess
		case designatedRequirement(SecRequirement)
		case adHoc
		case staticCode(SecStaticCode)
	}

	nonisolated private static let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "UpdateInstall")

	package private(set) var state: State = .idle

	package init() {}

	package func install(url: URL, sha256: String?, expectedVersion: String) async {
		switch state {
		case .downloading, .installing: return
		case .idle, .failed: break
		}
		guard let sha256, Self.isSHA256(sha256), ReleaseURLPolicy.isTrustedDownload(url) else {
			fail("The download didn't match. Try again.")
			return
		}
		let runningPath = Bundle.main.bundleURL.path
		guard !runningPath.contains("/AppTranslocation/"),
			FileManager.default.isWritableFile(
				atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
		else {
			fail("Move Gaze to Applications to install updates.")
			return
		}
		let current =
			Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
		var expected = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
		if expected.first == "v" || expected.first == "V" { expected.removeFirst() }
		guard !expected.isEmpty, ReleaseUpdateChecker.isNewer(expectedVersion, than: current) else {
			fail("This update couldn't be verified.")
			return
		}
		state = .downloading(fraction: 0)
		let (stream, continuation) = AsyncStream<Double>.makeStream()
		let job = Task.detached {
			await UpdateInstaller.runInstall(
				url: url, sha256: sha256, expectedVersion: expected,
				runningPath: runningPath, progress: continuation)
		}
		for await fraction in stream {
			state = .downloading(fraction: fraction)
		}
		switch await job.value {
		case .success(let swap):
			state = .installing
			Self.launch(swap: swap)
			NSApp.terminate(nil)
		case .failure(let failure):
			fail(failure.message)
		}
	}

	private func fail(_ message: String) {
		state = .failed(message)
	}

	private nonisolated static func isSHA256(_ value: String) -> Bool {
		value.count == 64
			&& value.utf8.allSatisfy {
				(48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
			}
	}

	/// Runs the helper script detached, so it survives this process quitting.
	private static func launch(swap: Swap) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = ["-c", "nohup /bin/bash \(shQuote(swap.scriptPath)) >/dev/null 2>&1 &"]
		do {
			try process.run()
		} catch {
			logger.error("Could not start the update helper: \(error.localizedDescription)")
		}
	}

	private nonisolated static func shQuote(_ value: String) -> String {
		"'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
	}

	// MARK: - Off-main-actor work

	package nonisolated static func runInstall(
		url: URL, sha256: String, expectedVersion: String, runningPath: String,
		progress: AsyncStream<Double>.Continuation
	) async -> Result<Swap, InstallFailure> {
		defer { progress.finish() }
		let tmp = FileManager.default.temporaryDirectory.appending(
			path: "GazeUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
		var staged: URL?
		do {
			guard isSHA256(sha256), ReleaseURLPolicy.isTrustedDownload(url) else {
				throw InstallFailure(message: "This update couldn't be verified.")
			}
			try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
			let dmg = tmp.appending(path: "Gaze.dmg", directoryHint: .notDirectory)
			try await download(url: url, to: dmg, progress: progress)
			Self.logger.notice("Update downloaded.")
			let digest = try sha256Hex(of: dmg)
			guard digest.lowercased() == sha256.lowercased() else {
				throw InstallFailure(message: "The download didn't match. Try again.")
			}
			Self.logger.notice("Update checksum verified.")
			let mount = try mount(dmg: dmg, randomRoot: tmp)
			Self.logger.notice("Update image mounted.")
			defer { detach(mount: mount) }
			let candidate = URL(fileURLWithPath: mount).appending(
				path: "Gaze.app", directoryHint: .isDirectory)
			try verify(app: candidate, expectedVersion: expectedVersion)
			Self.logger.notice("Update verified.")
			let parent = URL(fileURLWithPath: runningPath).deletingLastPathComponent()
			let stagedApp = parent.appending(
				path: ".Gaze-update-\(UUID().uuidString).app", directoryHint: .isDirectory)
			staged = stagedApp
			try ensureStagingSpace(for: candidate, parent: parent)
			try runProcess(
				"/usr/bin/ditto", [candidate.path, stagedApp.path],
				message: "Couldn't install the update. Try again.")
			try runProcess(
				"/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path],
				message: "Couldn't install the update. Try again.")
			Self.logger.notice("Update staged.")
			let script = tmp.appending(path: "update.sh", directoryHint: .notDirectory)
			try writeSwapScript(
				at: script, appPath: runningPath, stagedPath: stagedApp.path, tmpPath: tmp.path)
			Self.logger.notice("Update script written.")
			return .success(Swap(scriptPath: script.path))
		} catch let failure as InstallFailure {
			Self.logger.notice("Update failed: \(failure.message)")
			if let staged { try? FileManager.default.removeItem(at: staged) }
			try? FileManager.default.removeItem(at: tmp)
			return .failure(failure)
		} catch {
			Self.logger.notice("Update failed: couldn't install the update.")
			if let staged { try? FileManager.default.removeItem(at: staged) }
			try? FileManager.default.removeItem(at: tmp)
			return .failure(InstallFailure(message: "Couldn't install the update. Try again."))
		}
	}

	/// Fails when the volume holding the running app cannot fit the staged copy.
	package nonisolated static func ensureStagingSpace(for candidate: URL, parent: URL) throws {
		let needed = (try? stagedSize(of: candidate)) ?? (300 * 1024 * 1024)
		let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
		if let free = try? parent.resourceValues(forKeys: keys).volumeAvailableCapacityForImportantUsage {
			guard Int64(free) > needed + 200 * 1024 * 1024 else {
				throw InstallFailure(message: "Not enough disk space to install the update.")
			}
		}
	}

	package nonisolated static func stagedSize(of url: URL) throws -> Int64 {
		var size: Int64 = 0
		let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
		if let enumerator = FileManager.default.enumerator(
			at: url, includingPropertiesForKeys: Array(keys))
		{
			for case let file as URL in enumerator {
				let values = try file.resourceValues(forKeys: keys)
				if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
			}
		}
		return size
	}

	package nonisolated static func download(
		url: URL, to destination: URL, progress: AsyncStream<Double>.Continuation
	) async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpShouldSetCookies = false
		configuration.httpCookieStorage = nil
		configuration.urlCredentialStorage = nil
		configuration.urlCache = nil
		configuration.timeoutIntervalForRequest = 60
		configuration.timeoutIntervalForResource = 600
		let delegate = DownloadDelegate(destination: destination, progress: progress)
		let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		_ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
			delegate.setContinuation(continuation)
			session.downloadTask(with: url).resume()
		}
	}

	package nonisolated static func sha256Hex(of url: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher = SHA256()
		while true {
			guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
			hasher.update(data: chunk)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	package nonisolated static func mount(dmg: URL, randomRoot: URL) throws -> String {
		let output = try runProcess(
			"/usr/bin/hdiutil",
			["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", randomRoot.path, "-plist", dmg.path],
			message: "Couldn't install the update. Try again.")
		guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
			let entities = plist["system-entities"] as? [[String: Any]],
			let mount = entities.compactMap({ $0["mount-point"] as? String }).first
		else { throw InstallFailure(message: "Couldn't install the update. Try again.") }
		return mount
	}

	package nonisolated static func detach(mount: String) {
		_ = try? runProcess("/usr/bin/hdiutil", ["detach", "-force", mount], message: "")
	}

	package nonisolated static func verify(
		app: URL,
		expectedVersion: String,
		runningCodeRequirementPolicy: CodeRequirementPolicy = .runningProcess
	) throws {
		var expected = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
		if expected.first == "v" || expected.first == "V" { expected.removeFirst() }
		let parts = expected.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
		guard !parts.isEmpty, !parts[0].isEmpty,
			let data = try? Data(
				contentsOf: app.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)),
			let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
			let identifier = info["CFBundleIdentifier"] as? String,
			identifier == AppIdentity.bundleIdentifier,
			let version = info["CFBundleShortVersionString"] as? String,
			version == String(parts[0]),
			let build = info["CFBundleVersion"] as? String,
			!build.isEmpty,
			parts.count == 1 || build == String(parts[1])
		else { throw InstallFailure(message: "This update couldn't be verified.") }

		var mountedCode: SecStaticCode?
		guard SecStaticCodeCreateWithPath(app as CFURL, [], &mountedCode) == errSecSuccess,
			let mountedCode
		else { throw InstallFailure(message: "This update couldn't be verified.") }

		let requirement: SecRequirement?
		switch runningCodeRequirementPolicy {
		case .runningProcess:
			var ownCode: SecCode?
			var staticOwnCode: SecStaticCode?
			guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
				SecCodeCopyStaticCode(ownCode, [], &staticOwnCode) == errSecSuccess, let staticOwnCode
			else { throw InstallFailure(message: "This update couldn't be verified.") }
			requirement = try resolveRequirement(for: staticOwnCode)
		case .staticCode(let referenceCode):
			requirement = try resolveRequirement(for: referenceCode)
		case .designatedRequirement(let explicitRequirement):
			requirement = explicitRequirement
		case .adHoc:
			requirement = nil
		}

		let validationFlags = SecCSFlags(
			rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
		)
		guard SecStaticCodeCheckValidity(mountedCode, validationFlags, requirement) == errSecSuccess else {
			throw InstallFailure(message: "This update couldn't be verified.")
		}

		// In ad-hoc mode (requirement == nil), still verify the embedded CodeDirectory
		// identifier matches AppIdentity.bundleIdentifier rather than trusting Info.plist alone.
		if requirement == nil {
			var mountedInfoRef: CFDictionary?
			guard SecCodeCopySigningInformation(
				mountedCode,
				SecCSFlags(rawValue: kSecCSSigningInformation),
				&mountedInfoRef
			) == errSecSuccess,
				let mountedInfo = mountedInfoRef as? [String: Any],
				mountedInfo[kSecCodeInfoIdentifier as String] as? String == AppIdentity.bundleIdentifier
			else { throw InstallFailure(message: "This update couldn't be verified.") }
		}
	}

	private nonisolated static func resolveRequirement(for staticCode: SecStaticCode) throws -> SecRequirement? {
		var signingInfoRef: CFDictionary?
		guard SecCodeCopySigningInformation(
			staticCode,
			SecCSFlags(rawValue: kSecCSSigningInformation),
			&signingInfoRef
		) == errSecSuccess,
			let info = signingInfoRef as? [String: Any],
			let identifier = info[kSecCodeInfoIdentifier as String] as? String,
			!identifier.isEmpty
		else { throw InstallFailure(message: "This update couldn't be verified.") }

		let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
		let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
		guard let mode = CodeSigningMode.resolve(teamIdentifier: teamID, flags: flags) else {
			throw InstallFailure(message: "This update couldn't be verified.")
		}
		switch mode {
		case .teamSigned:
			var requirement: SecRequirement?
			guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
				let requirement
			else { throw InstallFailure(message: "This update couldn't be verified.") }
			return requirement
		case .adHoc:
			return nil
		}
	}

	@discardableResult
	package nonisolated static func runProcess(_ path: String, _ args: [String], message: String) throws -> Data {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: path)
		process.arguments = args
		let output = Pipe()
		process.standardOutput = output
		process.standardError = Pipe()
		try process.run()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { throw InstallFailure(message: message) }
		return output.fileHandleForReading.readDataToEndOfFile()
	}

	/// Waits for this process to exit, swaps the staged app in and reopens it.
	/// The app relaunches plainly with `open`: it is a login item
	/// (`SMAppService.mainApp`), not a launchd agent, so there is nothing to kickstart.
	/// Exits without swapping when the old process is still alive after the wait
	/// or another update already holds the lock. The menu-bar agent is removed
	/// before the swap so it cannot relaunch the half-replaced bundle, and the
	/// app only reopens when no running instance still owns the bundle path.
	package nonisolated static func writeSwapScript(at script: URL, appPath: String, stagedPath: String, tmpPath: String) throws {
		let pid = ProcessInfo.processInfo.processIdentifier
		let text = """
			#!/bin/bash
			APP=\(shQuote(appPath))
			STAGED=\(shQuote(stagedPath))
			TMP=\(shQuote(tmpPath))
			LOCK="$TMP/update.lock"
			if command -v flock >/dev/null 2>&1; then
			  exec 9>"$LOCK"
			  flock -n 9 || exit 1
			else
			  mkdir "$LOCK.dir" 2>/dev/null || exit 1
			  trap 'rmdir "$LOCK.dir" 2>/dev/null || true' EXIT
			fi
			for _ in $(seq 1 50); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
			if kill -0 \(pid) 2>/dev/null; then exit 1; fi
			/bin/launchctl remove \(AppIdentity.bundleIdentifier).agent 2>/dev/null || true
			mv "$APP" "$TMP/Gaze-previous.app"
			if ! mv "$STAGED" "$APP"; then mv "$TMP/Gaze-previous.app" "$APP"; exit 1; fi
			if ! /usr/bin/pgrep -qf "$APP/Contents/MacOS/Gaze" 2>/dev/null; then open "$APP"; fi
			rm -rf "$TMP"

			"""
		try text.write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
	}
}

package struct InstallFailure: Error, Sendable {
	package let message: String

	package init(message: String) {
		self.message = message
	}
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
	static let maximumBytes = 400 * 1024 * 1024

	private struct State: Sendable {
		var continuation: CheckedContinuation<URL, any Error>?
		var done = false
		var tooLarge = false
	}

	let destination: URL
	let progress: AsyncStream<Double>.Continuation
	private let state = Mutex(State())

	init(destination: URL, progress: AsyncStream<Double>.Continuation) {
		self.destination = destination
		self.progress = progress
	}

	func setContinuation(_ continuation: CheckedContinuation<URL, any Error>) {
		state.withLock { $0.continuation = continuation }
	}

	func urlSession(
		_ session: URLSession, task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
		completionHandler: @escaping @Sendable (URLRequest?) -> Void
	) {
		guard let url = request.url, ReleaseURLPolicy.isTrustedDownloadHop(url) else {
			completionHandler(nil)
			return
		}
		completionHandler(request)
	}

	func urlSession(
		_ session: URLSession, downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		if totalBytesWritten > Int64(Self.maximumBytes)
			|| (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > Int64(Self.maximumBytes))
		{
			state.withLock { $0.tooLarge = true }
			downloadTask.cancel()
			return
		}
		if totalBytesExpectedToWrite > 0 {
			progress.yield(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
		}
	}

	func urlSession(
		_ session: URLSession, downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		do {
			if let finalURL = downloadTask.response?.url, !ReleaseURLPolicy.isTrustedDownloadHop(finalURL) {
				throw InstallFailure(message: "This update couldn't be verified.")
			}
			let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? 0
			guard size <= Self.maximumBytes else {
				state.withLock { $0.tooLarge = true }
				downloadTask.cancel()
				return
			}
			try FileManager.default.moveItem(at: location, to: destination)
			finish(.success(destination))
		} catch {
			finish(.failure(error))
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
		let (done, tooLarge) = state.withLock { ($0.done, $0.tooLarge) }
		if done { return }
		if tooLarge {
			finish(.failure(InstallFailure(message: "The download is too large.")))
			return
		}
		if let error {
			finish(.failure(error))
			return
		}
		finish(.failure(InstallFailure(message: "Couldn't download the update. Try again.")))
	}

	private func finish(_ result: Result<URL, any Error>) {
		let continuation = state.withLock { state -> CheckedContinuation<URL, any Error>? in
			guard !state.done else { return nil }
			state.done = true
			let continuation = state.continuation
			state.continuation = nil
			return continuation
		}
		guard let continuation else { return }
		switch result {
		case .success(let url): continuation.resume(returning: url)
		case .failure(let error): continuation.resume(throwing: error)
		}
	}
}
