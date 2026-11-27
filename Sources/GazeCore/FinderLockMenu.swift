import Foundation

/// The Finder's contextual-menu decision. Foundation-only in GazeCore so the
/// Finder extension and tests share the exact same implementation.
public enum FinderLockMenu {

	public static let toggleScheme = AppIdentity.urlScheme
	public static let toggleHost = "app-lock"
	public static let togglePath = "/toggle"

	/// The menu title for a selection, or nil when no item applies: anything
	/// but one app, or an app that can never be locked.
	public static func title(selectedCount: Int, appBundleID: String?, isLocked: Bool) -> String? {
		guard selectedCount == 1, let bundleID = appBundleID, !bundleID.isEmpty,
			!AppLockStore.isNeverLockable(bundleID)
		else { return nil }
		return isLocked ? "Unlock with Gaze" : "Lock with Gaze"
	}

	/// The selection's bundle ID when it is a single .app, else nil.
	public static func bundleID(forAppURL url: URL) -> String? {
		guard url.pathExtension == "app" else { return nil }
		return Bundle(url: url)?.bundleIdentifier
	}

	public static func toggleURL(for bundleID: String) -> URL? {
		var parts = URLComponents()
		parts.scheme = toggleScheme
		parts.host = toggleHost
		parts.path = togglePath
		parts.queryItems = [URLQueryItem(name: "bundle", value: bundleID)]
		return parts.url
	}

	/// The bundle ID from a well-formed toggle URL, else nil. Mirrored by
	/// AppLockURLAction on the app side.
	public static func bundleID(fromToggleURL url: URL) -> String? {
		guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
			parts.scheme?.lowercased() == toggleScheme,
			parts.host?.lowercased() == toggleHost,
			parts.path == togglePath
		else { return nil }
		let bundleID = parts.queryItems?.first(where: { $0.name == "bundle" })?.value ?? ""
		return bundleID.isEmpty ? nil : bundleID
	}
}
