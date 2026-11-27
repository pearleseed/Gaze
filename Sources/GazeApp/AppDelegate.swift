import AppKit
import GazeCore
import GazeLockScreen
import GazeRecognition
import GazeSecurity
import GazeUpdates
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

	private var invisibleWindowSweep: Timer?

	/// The Finder extension's `gaze://app-lock/toggle` link. Each URL still goes
	/// through face or password authorisation inside AppLockURLAction; the
	/// click alone changes nothing.
	func application(_ application: NSApplication, open urls: [URL]) {
		guard urls.contains(where: { AppLockURLAction.bundleID(from: $0) != nil }) else { return }
		AppActivation.bringToFront(userInitiated: true)
		Task { @MainActor in
			let store = AppLockStore()
			for url in urls { _ = await AppLockURLAction.perform(url: url, store: store) }
		}
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if let openSettings = AppActivation.openSettings {
			openSettings()
			return false
		}
		// No live view holds `openWindow`: the menu bar icon is hidden and no
		// window has been shown since launch. Restore the icon — the person
		// asked for the app, and an app that cannot be opened is worse than
		// an icon back in the menu bar — then open Settings once its label
		// has registered the opener.
		Preferences.shared.showsMenuBarIcon = true
		AppActivation.bringToFront(userInitiated: true)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			MainActor.assumeIsolated {
				AppActivation.openSettings?()
			}
		}
		return false
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		let totalStart = StartupTiming.start()
		// Created now rather than at the first dark scan, so a brightness boost left
		// behind by a quit mid-scan is put back as soon as Gaze opens again.
		_ = LockScreenLight.shared
		// Load the face and anti-spoof models once, in the background, so the first
		// scan after launch (lock screen or App Lock) doesn't stop to load them.
		let embedder = AppServices.shared.store.embedder
		Task.detached(priority: .utility) {
			embedder.warmUp()
			SpoofDetector.shared?.warmUp()
			IrisLocator.warmUp()
		}
		StartupTiming.measure(label: "tamper-guard") { TamperGuard.shared.start() }
		StartupTiming.measure(label: "unlock-triggers") { AppServices.shared.startUnlockTrigger() }
		StartupTiming.measure(label: "app-lock") { AppServices.shared.syncAppLock() }
		// Sparkle 2 updater: checks the architecture-matched appcast with EdDSA verification.
		AppUpdater.shared.onWillRelaunch = { TamperGuard.shared.prepareForAuthorizedUpdateRelaunch() }
		if AppServices.executionPolicy == .normal {
			StartupTiming.measure(label: "update-scheduling") { AppUpdater.shared.start() }
		}
		StartupTiming.measure(label: "screenshot-mode") { AppServices.shared.runLockScreenShootIfRequested() }
		AppServices.shared.runAppLockPreviewIfRequested()
		StartupTiming.measure(label: "invisible-window-sweep") { self.startInvisibleWindowSweep() }
		// Native TipKit guidance, normal launches only: review and scan-only
		// modes neither configure TipKit nor mutate tip history.
		if AppServices.executionPolicy == .normal {
			StartupTiming.measure(label: "tips") { GazeTips.configure() }
		}
		StartupTiming.finish(label: "did-finish-launching-total", start: totalStart)
	}

	/// Makes any invisible window of ours click-through, for as long as the app runs.
	///
	/// SwiftUI's `MenuBarExtra` leaves a window behind at alpha 0, layer 101, parked under
	/// the menu bar item — 191×128 of dead screen in the top-right corner. Layer 101 is above
	/// every ordinary window and an invisible window still swallows clicks, so that rectangle
	/// stops working *in other applications* until this app quits.
	///
	/// Two earlier attempts did not hold. `.menuBarExtraStyle(.menu)` removed the panel that
	/// was there permanently but not this one, which arrives when the menu is used; and
	/// hanging the cleanup off `NSMenu.didEndTrackingNotification` assumed a notification that
	/// evidently does not always arrive. Guessing at *when* it appears has been wrong twice,
	/// so this stops guessing and simply checks.
	///
	/// It does not order the window out — SwiftUI owns that window and closing something it
	/// thinks is open invites a different bug. Making it click-through fixes precisely the
	/// reported problem and changes nothing anyone can see, since the window is invisible.
	///
	/// The window is found through the window server rather than `NSApp.windows`, because it
	/// is not reliably in that list, then matched back to an `NSWindow` by number.
	/// Fast sweep while the stray window might be around, backing off when it isn't.
	private static let invisibleSweepFastInterval: TimeInterval = 2.0
	private static let invisibleSweepSlowInterval: TimeInterval = 60.0
	private static let invisibleSweepCleanThreshold = 10

	private var invisibleCleanSweeps = 0
	private var invisibleSweepIsSlow = false

	@MainActor
	private func startInvisibleWindowSweep() {
		Self.clearInvisibleWindows()
		invisibleCleanSweeps = 0
		scheduleInvisibleSweep(interval: Self.invisibleSweepFastInterval, slow: false)
		// The window arrives when the menu is used, so menu tracking re-arms the fast
		// sweep. Only a hint, not the cleanup itself: if the notification does not
		// arrive, the slow sweep still catches it.
		NotificationCenter.default.addObserver(
			forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.rearmInvisibleSweep() }
		}
	}

	@MainActor
	private func scheduleInvisibleSweep(interval: TimeInterval, slow: Bool) {
		invisibleWindowSweep?.invalidate()
		invisibleSweepIsSlow = slow
		let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.invisibleSweepTick()
			}
		}
		// Common modes, or it stops firing while a menu is open — which is exactly when the
		// window in question appears.
		RunLoop.main.add(timer, forMode: .common)
		invisibleWindowSweep = timer
	}

	@MainActor
	private func invisibleSweepTick() {
		let fixed = Self.clearInvisibleWindows()
		if CommandLine.arguments.contains("--debug-windows") {
			Self.logAppWindows("tick")
		}
		guard fixed == 0 else {
			invisibleCleanSweeps = 0
			return
		}
		invisibleCleanSweeps += 1
		if invisibleCleanSweeps >= Self.invisibleSweepCleanThreshold && !invisibleSweepIsSlow {
			scheduleInvisibleSweep(interval: Self.invisibleSweepSlowInterval, slow: true)
		}
	}

	/// Back to the fast sweep: the stray window arrives when the menu is used.
	@MainActor
	private func rearmInvisibleSweep() {
		invisibleCleanSweeps = 0
		if invisibleSweepIsSlow {
			scheduleInvisibleSweep(interval: Self.invisibleSweepFastInterval, slow: false)
		}
	}

	/// Dumps what `NSApp.windows` actually contains, for diagnosing windows we cannot reach.
	@MainActor
	static func logAppWindows(_ note: String) {
		let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "Windows")
		logger.notice("--- NSApp.windows (\(note, privacy: .public)) ---")
		for w in NSApp.windows {
			logger.notice(
				"num=\(w.windowNumber) level=\(w.level.rawValue) alpha=\(w.alphaValue) visible=\(w.isVisible) ignoresMouse=\(w.ignoresMouseEvents) class=\(String(describing: type(of: w)), privacy: .public) frame=\(NSStringFromRect(w.frame), privacy: .public)"
			)
		}
	}

	/// Makes our invisible windows click-through. Returns how many were fixed.
	@MainActor
	@discardableResult
	static func clearInvisibleWindows() -> Int {
		let pid = ProcessInfo.processInfo.processIdentifier
		guard
			let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
				as? [[String: Any]]
		else { return 0 }

		var fixed = 0
		for entry in list {
			guard
				(entry[kCGWindowOwnerPID as String] as? Int32) == pid,
				let alpha = entry[kCGWindowAlpha as String] as? Double, alpha < 0.01,
				let number = entry[kCGWindowNumber as String] as? Int,
				let window = NSApp.window(withWindowNumber: number),
				!window.ignoresMouseEvents
			else { continue }

			window.ignoresMouseEvents = true
			fixed += 1
			Logger(subsystem: AppIdentity.loggerSubsystem, category: "Windows")
				.notice("Made an invisible window click-through: \(number)")
		}
		return fixed
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		TamperGuard.shared.authorizeQuit() ? .terminateNow : .terminateCancel
	}
}
