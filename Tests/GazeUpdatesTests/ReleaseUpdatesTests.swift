import Foundation
import GazeCore
import Security
import Synchronization
import Testing
@testable import GazeUpdates

// MARK: - URLProtocol Mock

private final class MockGitHubProtocol: URLProtocol, @unchecked Sendable {
	struct ResponseSpec: Sendable {
		var status: Int
		var body: Data
		var headers: [String: String]
		var redirectURL: URL?
		var delay: TimeInterval
		var error: URLError?

		init(
			status: Int = 200,
			body: Data = Data(),
			headers: [String: String] = [:],
			redirectURL: URL? = nil,
			delay: TimeInterval = 0,
			error: URLError? = nil
		) {
			self.status = status
			self.body = body
			self.headers = headers
			self.redirectURL = redirectURL
			self.delay = delay
			self.error = error
		}
	}

	struct RecordedRequest: Sendable {
		let url: URL
		let headers: [String: String]
	}

	private struct State: Sendable {
		var handler: (@Sendable (URLRequest) -> ResponseSpec)?
		var requests: [RecordedRequest] = []
		var pendingCount = 0
	}

	private static let state = Mutex(State())
	private let lock = NSLock()
	private var stopped = false
	private var pendingWork: DispatchWorkItem?

	static func reset(handler: @escaping @Sendable (URLRequest) -> ResponseSpec) {
		state.withLock {
			$0.handler = handler
			$0.requests.removeAll()
			$0.pendingCount = 0
		}
	}

	static var requests: [RecordedRequest] {
		state.withLock { $0.requests }
	}

	static var pendingCount: Int {
		state.withLock { $0.pendingCount }
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let (handler, url) = Self.state.withLock { state -> ((@Sendable (URLRequest) -> ResponseSpec)?, URL) in
			state.pendingCount += 1
			let requestURL = request.url ?? ReleaseURLPolicy.feed
			state.requests.append(RecordedRequest(url: requestURL, headers: request.allHTTPHeaderFields ?? [:]))
			return (state.handler, requestURL)
		}
		defer {
			Self.state.withLock { $0.pendingCount = max(0, $0.pendingCount - 1) }
		}

		let spec = handler?(request) ?? ResponseSpec(status: 404)
		if let error = spec.error {
			client?.urlProtocol(self, didFailWithError: error)
			return
		}

		if spec.delay > 0 {
			let work = DispatchWorkItem { [weak self] in
				guard let self else { return }
				self.deliver(spec: spec, url: url)
			}
			lock.lock()
			let alreadyStopped = stopped
			if !alreadyStopped { pendingWork = work }
			lock.unlock()
			if alreadyStopped {
				client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
			} else {
				DispatchQueue.global(qos: .userInitiated).asyncAfter(
					deadline: .now() + spec.delay, execute: work
				)
			}
			return
		}
		deliver(spec: spec, url: url)
	}

	private func deliver(spec: ResponseSpec, url: URL) {
		lock.lock()
		pendingWork = nil
		let isStopped = stopped
		lock.unlock()
		if isStopped {
			client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
			return
		}

		if let redirectURL = spec.redirectURL {
			let response = HTTPURLResponse(
				url: url,
				statusCode: 302,
				httpVersion: "HTTP/1.1",
				headerFields: ["Location": redirectURL.absoluteString]
			)!
			client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: response)
			return
		}

		var headers = spec.headers
		if headers["Content-Length"] == nil {
			headers["Content-Length"] = "\(spec.body.count)"
		}
		let response = HTTPURLResponse(
			url: url,
			statusCode: spec.status,
			httpVersion: "HTTP/1.1",
			headerFields: headers
		)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		if !spec.body.isEmpty {
			client?.urlProtocol(self, didLoad: spec.body)
		}
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {
		lock.lock()
		stopped = true
		let work = pendingWork
		pendingWork = nil
		lock.unlock()
		if let work {
			work.cancel()
			client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
		}
	}
}

// MARK: - Helpers

private func makeStubConfiguration() -> URLSessionConfiguration {
	let configuration = ReleaseURLPolicy.sessionConfiguration()
	configuration.protocolClasses = [MockGitHubProtocol.self]
	return configuration
}

@MainActor
private func withChecker(
	hostArchitecture: String = "arm64",
	currentVersion: String = "1.0.0",
	startupDelay: Duration = .milliseconds(40),
	_ body: @MainActor (ReleaseUpdateChecker, UserDefaults) async throws -> Void
) async throws {
	let suite = "com.pearleseed.Gaze.GazeUpdatesTests.\(UUID().uuidString)"
	let defaults = try #require(UserDefaults(suiteName: suite))
	defer { defaults.removePersistentDomain(forName: suite) }
	let checker = ReleaseUpdateChecker(
		defaults: defaults,
		sessionConfiguration: makeStubConfiguration,
		startupDelay: startupDelay,
		hostArchitecture: hostArchitecture,
		currentVersion: currentVersion
	)
	checker.notificationPoster = { _ in }
	try await body(checker, defaults)
}

private func githubReleaseJSON(
	tag: String = "v1.2.0",
	name: String? = "Gaze 1.2.0",
	body: String? = "Release notes",
	prerelease: Bool = false,
	draft: Bool = false,
	assets: [[String: Any]] = []
) throws -> Data {
	var object: [String: Any] = [
		"tag_name": tag,
		"prerelease": prerelease,
		"draft": draft,
		"assets": assets,
	]
	if let name { object["name"] = name }
	if let body { object["body"] = body }
	return try JSONSerialization.data(withJSONObject: object)
}

private func makeTemporaryAppBundle(
	bundleIdentifier: String = AppIdentity.bundleIdentifier,
	shortVersion: String = "1.2.0",
	buildVersion: String = "14",
	signingIdentifier: String? = nil,
	signAdHoc: Bool = true
) throws -> (root: URL, app: URL) {
	let root = FileManager.default.temporaryDirectory.appending(
		path: "GazeVerifyTest-\(UUID().uuidString)",
		directoryHint: .isDirectory
	)
	let app = root.appending(path: "Gaze.app", directoryHint: .isDirectory)
	let macos = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
	let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
	try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
	try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

	let executable = macos.appending(path: "Gaze", directoryHint: .notDirectory)
	try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
	try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
	try Data("sealed-model-payload".utf8).write(
		to: resources.appending(path: "Model.bin", directoryHint: .notDirectory)
	)

	let plist: [String: Any] = [
		"CFBundleIdentifier": bundleIdentifier,
		"CFBundleExecutable": "Gaze",
		"CFBundleName": "Gaze",
		"CFBundlePackageType": "APPL",
		"CFBundleShortVersionString": shortVersion,
		"CFBundleVersion": buildVersion,
		"LSMinimumSystemVersion": "26.0",
	]
	let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
	try plistData.write(to: app.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
	try Data("APPL????".utf8).write(to: app.appending(path: "Contents/PkgInfo", directoryHint: .notDirectory))

	if signAdHoc {
		var args = ["--force", "--deep", "--sign", "-"]
		if let signingIdentifier {
			args += ["-i", signingIdentifier]
		}
		args.append(app.path)
		try UpdateInstaller.runProcess("/usr/bin/codesign", args, message: "codesign fixture failed")
	}

	return (root, app)
}

// MARK: - Suites

@Suite("Release URL Policy")
struct ReleaseURLPolicyTests {
	@Test func endpointsUsePearleseedGitHub() {
		#expect(ReleaseURLPolicy.feed == URL(string: "https://api.github.com/repos/pearleseed/Gaze/releases/latest")!)
		#expect(ReleaseURLPolicy.releases == URL(string: "https://github.com/pearleseed/Gaze/releases")!)
	}

	@Test(arguments: [
		"https://api.github.com/repos/pearleseed/Gaze/releases/latest",
		"https://api.github.com/repos/pearleseed/Gaze/releases/assets/123456",
		"https://api.github.com:443/repos/pearleseed/Gaze/releases/latest",
	])
	func trustedFeedAccepted(_ raw: String) throws {
		let url = try #require(URL(string: raw))
		#expect(ReleaseURLPolicy.isTrustedFeed(url))
	}

	@Test(arguments: [
		"https://gazeunlock.com/api/latest",
		"https://api.github.com/repos/OwenCope/Gaze/releases/latest",
		"https://api.github.com/repos/pearleseed/Gaze/contents/README.md",
		"https://api.github.com/repos/pearleseed/Gaze/releases/latest/../assets/1",
		"https://github.com/pearleseed/Gaze/releases/latest",
		"http://api.github.com/repos/pearleseed/Gaze/releases/latest",
		"https://user@api.github.com/repos/pearleseed/Gaze/releases/latest",
		"https://api.github.com:8443/repos/pearleseed/Gaze/releases/latest",
		"https://api.github.com/repos/pearleseed/Gaze/releases/latest#frag",
	])
	func untrustedFeedRejected(_ raw: String) throws {
		let url = try #require(URL(string: raw))
		#expect(!ReleaseURLPolicy.isTrustedFeed(url))
	}

	@Test(arguments: [
		"https://github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze-1.0.0-1-arm64.dmg",
		"https://release-assets.githubusercontent.com/github-production-release-asset/123/Gaze.dmg",
		"https://objects.githubusercontent.com/github-production-release-asset/123?X-Amz-Algorithm=AWS4",
		"https://github.com:443/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
	])
	func trustedDownloadAndHopAccepted(_ raw: String) throws {
		let url = try #require(URL(string: raw))
		#expect(ReleaseURLPolicy.isTrustedDownload(url))
		#expect(ReleaseURLPolicy.isTrustedDownloadHop(url))
	}

	@Test(arguments: [
		"https://gazeunlock.com/releases/Gaze.dmg",
		"https://github.com/OwenCope/Gaze/releases/download/v1.0.0/Gaze.dmg",
		"https://github.com/pearleseed/Gaze/blob/main/README.md",
		"https://github.com/pearleseed/Gaze/releases",
		"https://github.com/pearleseed/Gaze/releases/download/../../OwenCope/Gaze/releases/download/v1.0.0/Gaze.dmg",
		"http://github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
		"https://user@github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
		"https://user:pass@objects.githubusercontent.com/asset",
		"https://github.com:8443/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
		"https://objects.githubusercontent.com/asset#fragment",
		"https://github.com.attacker.test/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
	])
	func untrustedDownloadAndHopRejected(_ raw: String) throws {
		let url = try #require(URL(string: raw))
		#expect(!ReleaseURLPolicy.isTrustedDownload(url))
		#expect(!ReleaseURLPolicy.isTrustedDownloadHop(url))
	}

	@Test func oversizedDownloadURLRejected() {
		let longURL = "https://github.com/pearleseed/Gaze/releases/download/v1.0.0/" + String(repeating: "a", count: 4096)
		#expect(ReleaseURLPolicy.download(longURL) == nil)
		#expect(ReleaseURLPolicy.download(nil) == nil)
	}
}

@Suite("GitHub Release Update Checker", .serialized)
@MainActor
struct ReleaseUpdateCheckerTests {
	private nonisolated static let validDigestHex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	private nonisolated static let altDigestHex = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

	@Test(arguments: ["arm64", "x86_64"])
	func selectsMatchingArchitectureAndExtractsDigest(_ arch: String) async throws {
		let armURL = "https://github.com/pearleseed/Gaze/releases/download/v1.2.0/Gaze-1.2.0-14-arm64.dmg"
		let x86URL = "https://github.com/pearleseed/Gaze/releases/download/v1.2.0/Gaze-1.2.0-14-x86_64.dmg"
		let payload = try githubReleaseJSON(
			tag: "v1.2.0",
			name: "Gaze 1.2.0",
			body: "Modernized release",
			assets: [
				[
					"name": "Gaze-1.2.0-14-arm64.dmg",
					"browser_download_url": armURL,
					"digest": "sha256:\(Self.validDigestHex.uppercased())",
				],
				[
					"name": "Gaze-1.2.0-14-x86_64.dmg",
					"browser_download_url": x86URL,
					"digest": "sha256:\(Self.altDigestHex)",
				],
			]
		)
		MockGitHubProtocol.reset { _ in
			.init(status: 200, body: payload)
		}

		try await withChecker(hostArchitecture: arch, currentVersion: "1.0.0") { checker, defaults in
			await checker.check()
			let expectedURL = URL(string: arch == "arm64" ? armURL : x86URL)!
			let expectedSHA = arch == "arm64" ? Self.validDigestHex : Self.altDigestHex
			#expect(
				checker.state == .available(.init(
					tag: "v1.2.0",
					name: "Gaze 1.2.0",
					notes: "Modernized release",
					downloadURL: expectedURL,
					downloadSHA256: expectedSHA
				))
			)
			#expect(defaults.object(forKey: "lastReleaseCheck") is Date)

			let feedRequest = try #require(MockGitHubProtocol.requests.first)
			#expect(feedRequest.headers["Accept"] == "application/vnd.github+json")
			#expect(feedRequest.headers["X-GitHub-Api-Version"] == "2022-11-28")
			#expect(feedRequest.headers["User-Agent"] == "Gaze/1.0.0")
		}
	}

	@Test func fallsBackToUniversalDMGWithoutSelectingWrongArchitecture() async throws {
		let universalURL = "https://github.com/pearleseed/Gaze/releases/download/v1.2.0/Gaze-1.2.0-14.dmg"
		let payloadUniversal = try githubReleaseJSON(
			tag: "v1.2.0",
			assets: [
				[
					"name": "Gaze-1.2.0-14.dmg",
					"browser_download_url": universalURL,
					"digest": "sha256:\(Self.validDigestHex)",
				],
			]
		)
		MockGitHubProtocol.reset { _ in .init(status: 200, body: payloadUniversal) }

		try await withChecker(hostArchitecture: "arm64", currentVersion: "1.0.0") { checker, _ in
			await checker.check()
			guard case .available(let release) = checker.state else {
				Issue.record("Expected available release, got \(checker.state)")
				return
			}
			#expect(release.downloadURL == URL(string: universalURL)!)
			#expect(release.downloadSHA256 == Self.validDigestHex)
		}

		let wrongArchOnly = try githubReleaseJSON(
			tag: "v1.2.0",
			assets: [
				[
					"name": "Gaze-1.2.0-14-x86_64.dmg",
					"browser_download_url": "https://github.com/pearleseed/Gaze/releases/download/v1.2.0/Gaze-1.2.0-14-x86_64.dmg",
					"digest": "sha256:\(Self.validDigestHex)",
				],
			]
		)
		MockGitHubProtocol.reset { _ in .init(status: 200, body: wrongArchOnly) }

		try await withChecker(hostArchitecture: "arm64", currentVersion: "1.0.0") { checker, _ in
			await checker.check()
			guard case .available(let release) = checker.state else {
				Issue.record("Expected available release, got \(checker.state)")
				return
			}
			#expect(release.downloadURL == nil)
			#expect(release.downloadSHA256 == nil)
		}
	}

	@Test func fetchesSidecarSHA256WhenDigestAbsent() async throws {
		let dmgURL = "https://github.com/pearleseed/Gaze/releases/download/v1.2.0/Gaze-1.2.0-14-arm64.dmg"
		let sidecarURL = "\(dmgURL).sha256"
		let redirectedURL = URL(string: "https://objects.githubusercontent.com/github-production-release-asset/123/Gaze-1.2.0-14-arm64.dmg.sha256")!
		let payload = try githubReleaseJSON(
			tag: "v1.2.0",
			assets: [
				[
					"name": "Gaze-1.2.0-14-arm64.dmg",
					"browser_download_url": dmgURL,
				],
				[
					"name": "Gaze-1.2.0-14-arm64.dmg.sha256",
					"browser_download_url": sidecarURL,
				],
			]
		)
		MockGitHubProtocol.reset { request in
			let url = request.url?.absoluteString ?? ""
			if url == ReleaseURLPolicy.feed.absoluteString {
				return .init(status: 200, body: payload)
			}
			if url == sidecarURL {
				return .init(redirectURL: redirectedURL)
			}
			if url == redirectedURL.absoluteString {
				return .init(status: 200, body: Data("\(Self.validDigestHex)  Gaze-1.2.0-14-arm64.dmg\n".utf8))
			}
			return .init(status: 404)
		}

		try await withChecker(hostArchitecture: "arm64", currentVersion: "1.0.0") { checker, _ in
			await checker.check()
			guard case .available(let release) = checker.state else {
				Issue.record("Expected available release, got \(checker.state)")
				return
			}
			#expect(release.downloadURL == URL(string: dmgURL)!)
			#expect(release.downloadSHA256 == Self.validDigestHex)
		}
	}

	@Test func oversizedOrMissingSHA256DegradesToBrowserDownloadOnly() async throws {
		let dmgURL = "https://github.com/pearleseed/Gaze/releases/download/v1.2.0/Gaze-1.2.0-14-arm64.dmg"
		let sidecarURL = "\(dmgURL).sha256"

		let noChecksumPayload = try githubReleaseJSON(
			tag: "v1.2.0",
			assets: [
				[
					"name": "Gaze-1.2.0-14-arm64.dmg",
					"browser_download_url": dmgURL,
				],
			]
		)
		MockGitHubProtocol.reset { _ in .init(status: 200, body: noChecksumPayload) }

		try await withChecker(hostArchitecture: "arm64", currentVersion: "1.0.0") { checker, _ in
			await checker.check()
			guard case .available(let release) = checker.state else {
				Issue.record("Expected available release, got \(checker.state)")
				return
			}
			#expect(release.downloadURL == URL(string: dmgURL)!)
			#expect(release.downloadSHA256 == nil)
		}

		let withOversizedSidecarPayload = try githubReleaseJSON(
			tag: "v1.2.0",
			assets: [
				[
					"name": "Gaze-1.2.0-14-arm64.dmg",
					"browser_download_url": dmgURL,
				],
				[
					"name": "Gaze-1.2.0-14-arm64.dmg.sha256",
					"browser_download_url": sidecarURL,
				],
			]
		)
		let oversizedBody = Data(repeating: UInt8(ascii: "a"), count: 4097)
		MockGitHubProtocol.reset { request in
			if request.url == ReleaseURLPolicy.feed {
				return .init(status: 200, body: withOversizedSidecarPayload)
			}
			return .init(status: 200, body: oversizedBody)
		}

		try await withChecker(hostArchitecture: "arm64", currentVersion: "1.0.0") { checker, _ in
			await checker.check()
			guard case .available(let release) = checker.state else {
				Issue.record("Expected available release, got \(checker.state)")
				return
			}
			#expect(release.downloadURL == URL(string: dmgURL)!)
			#expect(release.downloadSHA256 == nil)
		}
	}

	@Test func http404TreatsFreshForkAsUpToDateAndAdvancesTimestamp() async throws {
		MockGitHubProtocol.reset { _ in
			.init(status: 404, body: Data("{\"message\":\"Not Found\"}".utf8))
		}

		try await withChecker { checker, defaults in
			await checker.check()
			#expect(checker.state == .upToDate)
			#expect(defaults.object(forKey: "lastReleaseCheck") is Date)
		}
	}

	@Test(arguments: [(true, false), (false, true)])
	func draftAndPrereleaseTransitionToUpToDate(_ draft: Bool, _ prerelease: Bool) async throws {
		let payload = try githubReleaseJSON(
			tag: "v9.9.9",
			prerelease: prerelease,
			draft: draft,
			assets: [
				[
					"name": "Gaze-9.9.9-1-arm64.dmg",
					"browser_download_url": "https://github.com/pearleseed/Gaze/releases/download/v9.9.9/Gaze-9.9.9-1-arm64.dmg",
					"digest": "sha256:\(Self.validDigestHex)",
				],
			]
		)
		MockGitHubProtocol.reset { _ in .init(status: 200, body: payload) }

		try await withChecker { checker, defaults in
			await checker.check()
			#expect(checker.state == .upToDate)
			#expect(defaults.object(forKey: "lastReleaseCheck") is Date)
		}
	}

	@Test func stopScheduleMidFlightRestoresPreviousStateWithoutOfflineError() async throws {
		let payload = try githubReleaseJSON(tag: "v9.9.9")
		MockGitHubProtocol.reset { _ in
			.init(status: 200, body: payload, delay: 10)
		}

		try await withChecker(startupDelay: .milliseconds(20)) { checker, defaults in
			checker.startScheduledChecks()
			for _ in 0..<200 {
				if checker.state == .checking { break }
				try await Task.sleep(for: .milliseconds(10))
			}
			#expect(checker.state == .checking)
			checker.stopScheduledChecks()
			for _ in 0..<200 {
				if checker.state != .checking { break }
				try await Task.sleep(for: .milliseconds(10))
			}
			#expect(checker.state == .idle)
			#expect(defaults.object(forKey: "lastReleaseCheck") == nil)
		}
	}

	@Test func offlineFailureMentionsGitHubNotLegacyDomain() async throws {
		MockGitHubProtocol.reset { _ in
			.init(error: URLError(.notConnectedToInternet))
		}

		try await withChecker { checker, defaults in
			await checker.check()
			guard case .failed(let message) = checker.state else {
				Issue.record("Expected failure state")
				return
			}
			#expect(message.contains("GitHub"))
			#expect(!message.lowercased().contains("gazeunlock"))
			#expect(defaults.object(forKey: "lastReleaseCheck") == nil)
		}
	}
}

@Suite("Update Installer Verification & Policy")
@MainActor
struct UpdateInstallerTests {
	private static let validSHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

	@Test func installRefusesMissingOrInvalidSHA256OrUntrustedURL() async {
		let installer = UpdateInstaller()
		let trustedURL = URL(string: "https://github.com/pearleseed/Gaze/releases/download/v9.9.9/Gaze-9.9.9-1-arm64.dmg")!
		let untrustedURL = URL(string: "https://gazeunlock.com/releases/Gaze.dmg")!

		await installer.install(url: trustedURL, sha256: nil, expectedVersion: "v9.9.9")
		guard case .failed = installer.state else {
			Issue.record("Expected failure for nil sha256")
			return
		}

		let installer2 = UpdateInstaller()
		await installer2.install(url: trustedURL, sha256: "not-a-sha", expectedVersion: "v9.9.9")
		guard case .failed = installer2.state else {
			Issue.record("Expected failure for malformed sha256")
			return
		}

		let installer3 = UpdateInstaller()
		await installer3.install(url: untrustedURL, sha256: Self.validSHA, expectedVersion: "v9.9.9")
		guard case .failed = installer3.state else {
			Issue.record("Expected failure for untrusted URL")
			return
		}
	}

	@Test func verifiesValidAdHocBundleAndRejectsMismatchesAndTampering() throws {
		let (validRoot, validApp) = try makeTemporaryAppBundle(
			bundleIdentifier: AppIdentity.bundleIdentifier,
			shortVersion: "1.2.0",
			buildVersion: "14",
			signAdHoc: true
		)
		defer { try? FileManager.default.removeItem(at: validRoot) }

		// Explicit ad-hoc policy and static-code derived policy from an ad-hoc bundle both succeed.
		try UpdateInstaller.verify(app: validApp, expectedVersion: "v1.2.0+14", runningCodeRequirementPolicy: .adHoc)
		var staticValid: SecStaticCode?
		#expect(SecStaticCodeCreateWithPath(validApp as CFURL, [], &staticValid) == errSecSuccess)
		try UpdateInstaller.verify(
			app: validApp,
			expectedVersion: "1.2.0",
			runningCodeRequirementPolicy: .staticCode(try #require(staticValid))
		)

		// Wrong bundle ID rejected.
		let (wrongIDRoot, wrongIDApp) = try makeTemporaryAppBundle(
			bundleIdentifier: "com.evil.Gaze",
			shortVersion: "1.2.0",
			buildVersion: "14",
			signAdHoc: true
		)
		defer { try? FileManager.default.removeItem(at: wrongIDRoot) }
		#expect(throws: InstallFailure.self) {
			try UpdateInstaller.verify(app: wrongIDApp, expectedVersion: "v1.2.0", runningCodeRequirementPolicy: .adHoc)
		}

		// Wrong version rejected.
		#expect(throws: InstallFailure.self) {
			try UpdateInstaller.verify(app: validApp, expectedVersion: "v1.3.0", runningCodeRequirementPolicy: .adHoc)
		}
		#expect(throws: InstallFailure.self) {
			try UpdateInstaller.verify(app: validApp, expectedVersion: "v1.2.0+99", runningCodeRequirementPolicy: .adHoc)
		}

		// Mismatched signing identifier rejected even when Info.plist claims com.pearleseed.Gaze.
		let (wrongSigIDRoot, wrongSigIDApp) = try makeTemporaryAppBundle(
			bundleIdentifier: AppIdentity.bundleIdentifier,
			shortVersion: "1.2.0",
			buildVersion: "14",
			signingIdentifier: "com.evil.Other",
			signAdHoc: true
		)
		defer { try? FileManager.default.removeItem(at: wrongSigIDRoot) }
		#expect(throws: InstallFailure.self) {
			try UpdateInstaller.verify(app: wrongSigIDApp, expectedVersion: "v1.2.0", runningCodeRequirementPolicy: .adHoc)
		}

		// Unsigned bundle rejected.
		let (unsignedRoot, unsignedApp) = try makeTemporaryAppBundle(signAdHoc: false)
		defer { try? FileManager.default.removeItem(at: unsignedRoot) }
		#expect(throws: InstallFailure.self) {
			try UpdateInstaller.verify(app: unsignedApp, expectedVersion: "v1.2.0", runningCodeRequirementPolicy: .adHoc)
		}

		// Tampered sealed resource rejected after ad-hoc signing.
		let (tamperedRoot, tamperedApp) = try makeTemporaryAppBundle(signAdHoc: true)
		defer { try? FileManager.default.removeItem(at: tamperedRoot) }
		try Data("tampered".utf8).write(
			to: tamperedApp.appending(path: "Contents/Resources/Model.bin", directoryHint: .notDirectory)
		)
		#expect(throws: InstallFailure.self) {
			try UpdateInstaller.verify(app: tamperedApp, expectedVersion: "v1.2.0", runningCodeRequirementPolicy: .adHoc)
		}
	}

	@Test func releaseInstallabilityRequiresBothDownloadURLAndSHA256() {
		let url = URL(string: "https://github.com/pearleseed/Gaze/releases/download/v1.2.0/Gaze-1.2.0-14-arm64.dmg")!
		#expect(ReleaseUpdateChecker.Release(tag: "v1.2.0", name: "Gaze", notes: "", downloadURL: url, downloadSHA256: Self.validSHA).isInstallable)
		#expect(!ReleaseUpdateChecker.Release(tag: "v1.2.0", name: "Gaze", notes: "", downloadURL: url, downloadSHA256: nil).isInstallable)
		#expect(!ReleaseUpdateChecker.Release(tag: "v1.2.0", name: "Gaze", notes: "", downloadURL: nil, downloadSHA256: Self.validSHA).isInstallable)
	}

	@Test func teamSignedRequirementRejectsAdHocAndWrongTeamApps() throws {
		let (adHocRoot, adHocApp) = try makeTemporaryAppBundle(signAdHoc: true)
		defer { try? FileManager.default.removeItem(at: adHocRoot) }

		var teamRequirement: SecRequirement?
		let status = SecRequirementCreateWithString(
			"identifier \"com.pearleseed.Gaze\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAM123456\"" as CFString,
			[],
			&teamRequirement
		)
		#expect(status == errSecSuccess)
		let requirement = try #require(teamRequirement)

		#expect(throws: InstallFailure.self) {
			try UpdateInstaller.verify(
				app: adHocApp,
				expectedVersion: "v1.2.0",
				runningCodeRequirementPolicy: .designatedRequirement(requirement)
			)
		}

		// Policy decision helper selects team-signed when Team ID is present, ad-hoc when ad-hoc flag is set, and rejects unsigned.
		#expect(
			UpdateInstaller.CodeSigningMode.resolve(teamIdentifier: "3MZSQLPMVV", flags: 0) == .teamSigned
		)
		#expect(
			UpdateInstaller.CodeSigningMode.resolve(teamIdentifier: nil, flags: SecCodeSignatureFlags.adhoc.rawValue) == .adHoc
		)
		#expect(
			UpdateInstaller.CodeSigningMode.resolve(teamIdentifier: nil, flags: 0) == nil
		)
	}

	@Test func swapScriptRemovesPearleseedAgent() throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "GazeSwapTest-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }

		let script = dir.appending(path: "update.sh", directoryHint: .notDirectory)
		try UpdateInstaller.writeSwapScript(
			at: script,
			appPath: "/Applications/Gaze.app",
			stagedPath: "/Applications/.Gaze-update.app",
			tmpPath: dir.path
		)
		let contents = try String(contentsOf: script, encoding: .utf8)
		#expect(contents.contains("com.pearleseed.Gaze.agent"))
		#expect(!contents.lowercased().contains("gazeunlock"))
	}
}
