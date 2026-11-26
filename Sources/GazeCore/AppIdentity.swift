import Foundation

/// Single source of truth for Pearleseed Gaze's bundle, IPC, storage, logging, and repository identifiers.
public enum AppIdentity {
	public static let bundleIdentifier = "com.pearleseed.Gaze"
	public static let finderExtensionIdentifier = "com.pearleseed.Gaze.Finder"
	public static let appGroupIdentifier = "group.com.pearleseed.Gaze"
	public static let keychainService = "com.pearleseed.Gaze"
	public static let loggerSubsystem = "com.pearleseed.Gaze"
	public static let statusNotificationPrefix = "com.pearleseed.Gaze.status."
	public static let stateNotificationName = "com.pearleseed.Gaze.state"
	public static let pendingSettingsPaneKey = "com.pearleseed.Gaze.pendingSettingsPane"
	public static let urlScheme = "gaze"
	public static let repositorySlug = "pearleseed/Gaze"
	public static let repositoryURL = URL(string: "https://github.com/pearleseed/Gaze")!
	public static let releasesURL = URL(string: "https://github.com/pearleseed/Gaze/releases")!
	public static let issuesURL = URL(string: "https://github.com/pearleseed/Gaze/issues")!
}
