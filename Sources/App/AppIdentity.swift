import Foundation

/// Single source of truth for Pearleseed Gaze's bundle, IPC, storage, logging, and repository identifiers.
enum AppIdentity {
	static let bundleIdentifier = "com.pearleseed.Gaze"
	static let finderExtensionIdentifier = "com.pearleseed.Gaze.Finder"
	static let appGroupIdentifier = "group.com.pearleseed.Gaze"
	static let keychainService = "com.pearleseed.Gaze"
	static let loggerSubsystem = "com.pearleseed.Gaze"
	static let statusNotificationPrefix = "com.pearleseed.Gaze.status."
	static let stateNotificationName = "com.pearleseed.Gaze.state"
	static let pendingSettingsPaneKey = "com.pearleseed.Gaze.pendingSettingsPane"
	static let urlScheme = "gaze"
	static let repositorySlug = "pearleseed/Gaze"
	static let repositoryURL = URL(string: "https://github.com/pearleseed/Gaze")!
	static let releasesURL = URL(string: "https://github.com/pearleseed/Gaze/releases")!
	static let issuesURL = URL(string: "https://github.com/pearleseed/Gaze/issues")!
}
