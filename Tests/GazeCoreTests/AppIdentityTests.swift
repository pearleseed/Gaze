import Foundation
import GazeCore
import Testing

@Suite("App Identity Constants")
struct AppIdentityTests {
	@Test func identifiersUsePearleseedNamespace() {
		#expect(AppIdentity.bundleIdentifier == "com.pearleseed.Gaze")
		#expect(AppIdentity.finderExtensionIdentifier == "com.pearleseed.Gaze.Finder")
		#expect(AppIdentity.appGroupIdentifier == "group.com.pearleseed.Gaze")
		#expect(AppIdentity.keychainService == "com.pearleseed.Gaze")
		#expect(AppIdentity.loggerSubsystem == "com.pearleseed.Gaze")
		#expect(AppIdentity.pendingSettingsPaneKey == "com.pearleseed.Gaze.pendingSettingsPane")
		#expect(AppIdentity.urlScheme == "gaze")
	}

	@Test func repositoryURLsPointToPearleseedGitHub() {
		#expect(AppIdentity.repositorySlug == "pearleseed/Gaze")
		#expect(AppIdentity.repositoryURL == URL(string: "https://github.com/pearleseed/Gaze")!)
		#expect(AppIdentity.releasesURL == URL(string: "https://github.com/pearleseed/Gaze/releases")!)
		#expect(AppIdentity.issuesURL == URL(string: "https://github.com/pearleseed/Gaze/issues")!)
	}

	@Test func noLegacyUpstreamStringsAppearInIdentity() {
		let allValues = [
			AppIdentity.bundleIdentifier,
			AppIdentity.finderExtensionIdentifier,
			AppIdentity.appGroupIdentifier,
			AppIdentity.keychainService,
			AppIdentity.loggerSubsystem,
			AppIdentity.pendingSettingsPaneKey,
			AppIdentity.urlScheme,
			AppIdentity.repositorySlug,
			AppIdentity.repositoryURL.absoluteString,
			AppIdentity.releasesURL.absoluteString,
			AppIdentity.issuesURL.absoluteString,
		]
		for value in allValues {
			let lower = value.lowercased()
			#expect(!lower.contains("gazeunlock"))
			#expect(!lower.contains("owencope"))
		}
	}
}
