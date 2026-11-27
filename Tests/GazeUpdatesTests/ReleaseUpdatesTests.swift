import Foundation
import GazeCore
import Testing
@testable import GazeUpdates

@Suite("Sparkle 2 Updates — Feed Policy, Info.plist Invariants & State")
@MainActor
struct AppUpdaterTests {
	private static func repositoryRoot() -> URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
	}

	@Test func feedURLSelectsArchitectureSpecificAppcast() {
		#expect(
			AppUpdater.feedURL(for: "arm64").absoluteString
				== "https://github.com/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml"
		)
		#expect(
			AppUpdater.feedURL(for: "x86_64").absoluteString
				== "https://github.com/pearleseed/Gaze/releases/latest/download/appcast-x86_64.xml"
		)
		// Unknown architectures safely default to arm64.
		#expect(
			AppUpdater.feedURL(for: "unknown").absoluteString
				== "https://github.com/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml"
		)
	}

	@Test func trustedFeedURLPolicyAcceptsOnlyRepositoryHTTPSAppcasts() {
		for valid in [
			"https://github.com/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml",
			"https://github.com/pearleseed/Gaze/releases/latest/download/appcast-x86_64.xml",
			"https://github.com:443/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml",
		] {
			let url = URL(string: valid)!
			#expect(AppUpdater.isTrustedFeedURL(url))
		}

		for invalid in [
			"http://github.com/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml",
			"https://github.com/other/Gaze/releases/latest/download/appcast-arm64.xml",
			"https://github.com.evil.example/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml",
			"https://github.com:8443/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml",
			"https://user:pass@github.com/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml",
			"https://github.com/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml?foo=bar",
			"https://github.com/pearleseed/Gaze/releases/latest/download/appcast-arm64.xml#frag",
			"https://github.com/pearleseed/Gaze/releases/latest/download/other.xml",
		] {
			let url = URL(string: invalid)!
			#expect(!AppUpdater.isTrustedFeedURL(url))
		}
	}

	@Test func infoPlistCarriesValidSparkle2SecurityConfiguration() throws {
		let plistURL = Self.repositoryRoot().appendingPathComponent("Resources/Info.plist")
		let data = try Data(contentsOf: plistURL)
		let plist = try #require(
			PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
		)

		let feedString = try #require(plist["SUFeedURL"] as? String)
		let feedURL = try #require(URL(string: feedString))
		#expect(AppUpdater.isTrustedFeedURL(feedURL))

		let publicKeyBase64 = try #require(plist["SUPublicEDKey"] as? String)
		let publicKeyData = try #require(Data(base64Encoded: publicKeyBase64))
		#expect(publicKeyData.count == 32)

		#expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
		#expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
	}

	@Test func updaterInitializesDefaultsCleanlyWithoutStartingSparkleInTests() throws {
		let suite = "com.pearleseed.Gaze.AppUpdaterTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		let updater = AppUpdater(defaults: defaults, hostArchitecture: "arm64")
		#expect(!updater.canCheckForUpdates)
		#expect(updater.availableUpdateVersion == nil)
		#expect(updater.lastUpdateCheckDate == nil)
		#expect(updater.automaticallyChecksForUpdates)
		#expect(!updater.automaticallyDownloadsUpdates)
	}

	@Test func repoRevealHelperReportsBundleVersion() {
		let helper = RepoRevealHelper()
		#expect(!helper.currentVersion.isEmpty)
	}
}
