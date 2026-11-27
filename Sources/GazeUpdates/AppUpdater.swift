import AppKit
import Foundation
import GazeCore
import Observation
import Sparkle
import UserNotifications
import os

/// Coordinates Sparkle 2 software updates for Gaze.
///
/// Selects the host-architecture appcast feed (`appcast-arm64.xml` or `appcast-x86_64.xml`),
/// verifies EdDSA signatures before extraction (via `SUPublicEDKey` and
/// `SUVerifyUpdateBeforeExtraction` in `Info.plist`), defers background checks while the
/// screen is locked, and uses gentle notifications for menu-bar background discoveries.
@Observable
@MainActor
package final class AppUpdater {

	package static let shared = AppUpdater()

	private static let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "Updates")
	nonisolated private static let notificationID = "\(AppIdentity.bundleIdentifier).update-available"
	private static let lastNotifiedVersionKey = "lastNotifiedSparkleVersion"

	package static var currentHostArchitecture: String {
		#if arch(arm64)
		return "arm64"
		#elseif arch(x86_64)
		return "x86_64"
		#else
		return "arm64"
		#endif
	}

	/// Returns the HTTPS GitHub Releases appcast feed URL for the given CPU architecture.
	package static func feedURL(for architecture: String = currentHostArchitecture) -> URL {
		let arch = architecture == "x86_64" ? "x86_64" : "arm64"
		return URL(string: "https://github.com/\(AppIdentity.repositorySlug)/releases/latest/download/appcast-\(arch).xml")!
	}

	/// Validates that a feed URL points strictly to this repository's HTTPS Sparkle appcast.
	package static func isTrustedFeedURL(_ url: URL) -> Bool {
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			components.scheme?.lowercased() == "https",
			components.host?.lowercased() == "github.com",
			components.user == nil,
			components.password == nil,
			components.port == nil || components.port == 443,
			components.fragment == nil,
			components.query == nil
		else { return false }
		let validPaths = Set([
			"/\(AppIdentity.repositorySlug)/releases/latest/download/appcast-arm64.xml",
			"/\(AppIdentity.repositorySlug)/releases/latest/download/appcast-x86_64.xml",
		])
		return validPaths.contains(components.path)
	}

	package private(set) var canCheckForUpdates = false
	package private(set) var availableUpdateVersion: String?
	package private(set) var lastUpdateCheckDate: Date?

	package var automaticallyChecksForUpdates: Bool {
		didSet {
			guard oldValue != automaticallyChecksForUpdates, let updater = controller?.updater else { return }
			if updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
				updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
			}
			if !automaticallyChecksForUpdates, automaticallyDownloadsUpdates {
				automaticallyDownloadsUpdates = false
			}
		}
	}

	package var automaticallyDownloadsUpdates: Bool {
		didSet {
			guard oldValue != automaticallyDownloadsUpdates, let updater = controller?.updater else { return }
			if updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates {
				updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
			}
		}
	}

	/// Invoked right before Sparkle terminates and relaunches Gaze to install a verified update.
	@ObservationIgnored package var onWillRelaunch: (@MainActor () -> Void)?

	@ObservationIgnored private var controller: SPUStandardUpdaterController?
	@ObservationIgnored private var delegateBridge: SparkleDelegateBridge?
	@ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private let hostArchitecture: String

	package init(
		defaults: UserDefaults = .standard,
		hostArchitecture: String = AppUpdater.currentHostArchitecture
	) {
		self.defaults = defaults
		self.hostArchitecture = hostArchitecture
		self.automaticallyChecksForUpdates = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
		self.automaticallyDownloadsUpdates = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? false
	}

	/// Starts Sparkle's updater controller. Safe to call multiple times.
	package func start() {
		guard controller == nil else { return }
		let bridge = SparkleDelegateBridge(owner: self, hostArchitecture: hostArchitecture)
		let controller = SPUStandardUpdaterController(
			startingUpdater: true,
			updaterDelegate: bridge,
			userDriverDelegate: bridge
		)
		self.delegateBridge = bridge
		self.controller = controller

		let updater = controller.updater
		automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
		automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
		lastUpdateCheckDate = updater.lastUpdateCheckDate

		canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
			let canCheck = change.newValue ?? false
			Task { @MainActor [weak self] in
				self?.canCheckForUpdates = canCheck
			}
		}
		Self.logger.notice("Sparkle 2 updater started (feed: \(Self.feedURL(for: self.hostArchitecture).absoluteString, privacy: .public))")
	}

	/// Initiates a user-driven update check and brings Sparkle's UI to the foreground.
	package func checkForUpdates() {
		if controller == nil { start() }
		AppActivation.bringToFront(userInitiated: true)
		controller?.checkForUpdates(nil)
	}

	// MARK: - Internal Delegate Callbacks

	fileprivate func handleFoundUpdate(displayVersion: String) {
		availableUpdateVersion = displayVersion
	}

	fileprivate func handleNoUpdateFound() {
		availableUpdateVersion = nil
	}

	fileprivate func handleFinishedCycle(lastCheckDate: Date?) {
		lastUpdateCheckDate = lastCheckDate
	}

	fileprivate func handleWillShowUpdate(
		handledByStandardDriver: Bool,
		displayVersion: String
	) {
		availableUpdateVersion = displayVersion
		if handledByStandardDriver {
			AppActivation.bringToFront(userInitiated: true)
		} else {
			postGentleNotificationIfNeeded(for: displayVersion)
		}
	}

	fileprivate func handleUserAttention() {
		clearDeliveredNotification()
	}

	fileprivate func handleFinishUpdateSession() {
		clearDeliveredNotification()
		availableUpdateVersion = nil
	}

	fileprivate func handleWillRelaunch() {
		onWillRelaunch?()
	}

	// MARK: - Gentle Notifications

	private static var isAppBundle: Bool {
		Bundle.main.bundleURL.pathExtension == "app"
	}

	private func postGentleNotificationIfNeeded(for version: String) {
		guard defaults.string(forKey: Self.lastNotifiedVersionKey) != version else { return }
		defaults.set(version, forKey: Self.lastNotifiedVersionKey)
		guard Self.isAppBundle else { return }

		let center = UNUserNotificationCenter.current()
		UpdateNotificationDelegate.shared.register(with: center, updater: self)
		Task { @MainActor in
			guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
			let content = UNMutableNotificationContent()
			content.title = "Gaze \(version) is available"
			content.body = "Click to review release notes and install the verified update."
			content.sound = .default
			let request = UNNotificationRequest(
				identifier: Self.notificationID,
				content: content,
				trigger: nil
			)
			try? await center.add(request)
		}
	}

	private func clearDeliveredNotification() {
		guard Self.isAppBundle else { return }
		UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
	}
}

// MARK: - Sparkle Delegates

private final class SparkleDelegateBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
	private weak var owner: AppUpdater?
	private let hostArchitecture: String

	init(owner: AppUpdater, hostArchitecture: String) {
		self.owner = owner
		self.hostArchitecture = hostArchitecture
		super.init()
	}

	// MARK: SPUUpdaterDelegate (@MainActor via NS_SWIFT_UI_ACTOR)

	func feedURLString(for updater: SPUUpdater) -> String? {
		AppUpdater.feedURL(for: hostArchitecture).absoluteString
	}

	func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
		if updateCheck == .updatesInBackground && Self.isScreenLocked() {
			throw NSError(
				domain: AppIdentity.bundleIdentifier,
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Deferred background update check while the screen is locked."]
			)
		}
	}

	func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
		owner?.handleFoundUpdate(displayVersion: item.displayVersionString)
	}

	func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
		owner?.handleNoUpdateFound()
	}

	func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
		owner?.handleFinishedCycle(lastCheckDate: updater.lastUpdateCheckDate)
	}

	func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
		owner?.handleWillRelaunch()
	}

	// MARK: SPUStandardUserDriverDelegate

	nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

	nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
		_ update: SUAppcastItem,
		andInImmediateFocus immediateFocus: Bool
	) -> Bool {
		// Menu-bar app: never interrupt the user with an unsolicited update sheet.
		false
	}

	nonisolated func standardUserDriverWillHandleShowingUpdate(
		_ handleShowingUpdate: Bool,
		forUpdate update: SUAppcastItem,
		state: SPUUserUpdateState
	) {
		let version = update.displayVersionString
		MainActor.assumeIsolated {
			owner?.handleWillShowUpdate(
				handledByStandardDriver: handleShowingUpdate,
				displayVersion: version
			)
		}
	}

	nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
		MainActor.assumeIsolated {
			owner?.handleUserAttention()
		}
	}

	nonisolated func standardUserDriverWillFinishUpdateSession() {
		MainActor.assumeIsolated {
			owner?.handleFinishUpdateSession()
		}
	}

	nonisolated func standardUserDriverWillShowModalAlert() {
		MainActor.assumeIsolated {
			AppActivation.bringToFront(userInitiated: true)
		}
	}

	private static func isScreenLocked() -> Bool {
		guard
			let session = CGSessionCopyCurrentDictionary() as? [String: Any],
			let locked = session["CGSSessionScreenIsLocked"] as? Bool
		else { return false }
		return locked
	}
}

// MARK: - Notification Delegate

private final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
	static let shared = UpdateNotificationDelegate()

	private weak var updater: AppUpdater?

	func register(with center: UNUserNotificationCenter, updater: AppUpdater) {
		self.updater = updater
		if center.delegate == nil {
			center.delegate = self
		}
	}

	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse,
		withCompletionHandler completionHandler: @escaping () -> Void
	) {
		Task { @MainActor [weak self] in
			self?.updater?.checkForUpdates()
		}
		completionHandler()
	}
}
