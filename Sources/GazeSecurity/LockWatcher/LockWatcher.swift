import AppKit
import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import GazeLockScreen
import GazeRecognition
import IOKit
import IOKit.pwr_mgt
import Observation
import os

/// Watches for the screen locking and drives a face unlock attempt.
///
/// This is the trigger the keystroke backend needs. The authorization-plugin path gets
/// invoked by macOS itself, but password replay has no such hook — the app has to notice
/// the lock screen appear, look for a face, and type the password. Nothing else calls it.
///
/// Deliberately does nothing until the screen is actually locked. Running the camera
/// speculatively would burn battery and light the recording indicator for no reason.
@Observable
@MainActor
package final class LockWatcher {

	internal static let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "LockWatcher")
	internal static let renderTimingLogger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "RenderTiming")

	internal let store: FaceEnrollmentStore
	internal let lockout: LockoutManager

	internal var attempt: Task<Void, Never>?
	internal var attemptID: UUID?
	internal var diagnosticID: UUID?
	/// Whether this lock produced a recognised face and a submitted password.
	///
	/// The unlock animation must only play when *we* did it. The screen unlocking is not by
	/// itself evidence of that — Touch ID, a typed password and a paired Watch all raise the
	/// same notification, and playing "Gaze opened this" over someone else's unlock is a
	/// claim the app has no basis for.
	internal var didSubmitPassword = false
	internal var submissionID: UUID?
	internal static var submissionBudget = LockScreenSubmissionBudget()
	internal static var manualInputObserved = false
	/// When the last wake trigger was honoured, so `didWake` + `screensDidWake` count as one.
	internal var lastWakeTrigger: ContinuousClock.Instant?
	/// Block-observer tokens, so `stop()` can actually unregister them.
	internal var observers: [NSObjectProtocol] = []
	package private(set) var isWatching = false
	package private(set) var isLocked = false
	/// Whether the screen saver is currently running. While it covers the screen,
	/// scanning would light the camera with no panel visible.
	internal var screenSaverRunning = false
	internal var screenSaverStartedAt: ContinuousClock.Instant?
	/// Whether the MacBook lid was closed when entering sleep, so only a true
	/// closed→open lid transition uses `lidOpenSettle`.
	internal var clamshellClosedAtSleep = false
	/// Timestamp of the last sleep/display-sleep notification, used by `wakeProbe` to
	/// wait briefly for `CGSSessionScreenIsLocked` or external displays to settle on wake.
	internal var lastSleepAt: ContinuousClock.Instant?
	/// When a look last had to turn the dark-room light on.
	internal static var lightNeededAt: Date?
	/// Listens for Space on the lock screen so it retries the scan. Started with the
	/// lock, stopped with the unlock; never runs otherwise.
	internal let spaceMonitor = SpaceKeyMonitor()
	/// When the monitor last saw Space. A press it saw is a retry request, not typing:
	/// the input guard forgives exactly one keyDown within 300 ms of it.
	internal var lastSpaceAt: Date?
	/// Set once Gaze has explained why it isn't looking on this lock, so the reason
	/// shows once rather than on every wake and Space press.
	internal var explainedStandDown = false
	/// Every Space the monitor has reported. The scan forgives exactly this many key
	/// presses, so pressing Space repeatedly never reads as typing a password.
	internal var spacePresses = 0

	internal let capsule = NotchCapsuleController()
	/// Checks the window server while the Mac is locked, in case the unlock notification
	/// never arrives or arrives before the session stops reporting locked.
	internal var unlockWatchdog: Task<Void, Never>?
	/// After a scan ends with the Mac still locked, waits for the pointer to move and
	/// looks again, so trying once more does not mean closing the lid.
	internal var pointerRetry: Task<Void, Never>?
	/// Bounded re-check after a wake notification when displays or lock state are still
	/// transitioning (common when waking from Apple → Sleep or with external monitors).
	internal var wakeProbe: Task<Void, Never>?
	/// Cancellable retry for `screenUnlocked()` when `AutofillConsoleSession` lags behind
	/// `com.apple.screenIsUnlocked`.
	internal var unlockRetryTask: Task<Void, Never>?
	/// Cancellable grace check after password submission.
	internal var submissionCheckTask: Task<Void, Never>?
	/// Set by the attempt when the camera never started or stopped sending frames, the
	/// one failure worth an automatic second try.
	internal var cameraFailed = false
	/// The most recent matched print this lock, learned only after the Mac confirms
	/// the unlock was ours. A match alone is not a confirmed Gaze unlock, and learning
	/// from anything less would let a near-miss write itself into the vault.
	internal var pendingLearnedPrint: (print: Faceprint, faceID: UUID)?
	/// When the current attempt began, for unlock timing and durations.
	internal var attemptStartedAt: ContinuousClock.Instant?
	internal var cameraRunningAt: ContinuousClock.Instant?
	internal var firstFrameAt: ContinuousClock.Instant?
	internal var firstMatchAt: ContinuousClock.Instant?
	internal var passwordSubmittedAt: ContinuousClock.Instant?
	/// When the movement prompt was shown, for unlock timing bookkeeping.
	internal var movementPresentedAt: ContinuousClock.Instant?
	/// Seconds from the movement prompt appearing to it being completed.
	internal var movementDuration: TimeInterval?
	/// The prompt text shown for the movement challenge.
	internal var movementPrompt: String?
	/// The Follow-the-light per-pass scores at completion, for the attempts log.
	internal var movementLookPasses: [String]?
	/// The last face frame seen this lock, kept for the attempts log only.
	internal var lastFacePixelBuffer: CVPixelBuffer?
	/// Whether this lock already filed an ended-without-Gaze attempt. One
	/// per lock: retries must not each file one.
	internal var closedAttemptLogged = false

	/// How long the opened padlock stays before the panel goes home.
	///
	/// Three seconds, not one. The Mac is already unlocked by this point, so the padlock is
	/// costing nobody anything — and it is the only part of the sequence you get to look at
	/// without a login window in front of it.
	private static let unlockAnimationDuration: TimeInterval = 3.0

	internal static let wakeSettle = LockWakePolicy.wakeSettle

	/// Whether the MacBook lid is currently closed. Desktops report no clamshell state
	/// and read false here, so they always keep the full wake settle.
	internal static func isClamshellClosed() -> Bool {
		let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
		guard service != IO_OBJECT_NULL else { return false }
		defer { IOObjectRelease(service) }
		guard let state = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool else { return false }
		return state
	}

	package init(store: FaceEnrollmentStore, lockout: LockoutManager) {
		self.store = store
		self.lockout = lockout
		// Main thread only: the monitor's callback runs on the main run loop.
		spaceMonitor.onSpaceKeyDown = { [weak self] in
			MainActor.assumeIsolated { self?.handleSpaceKey() }
		}
	}

	package func start() {
		guard !isWatching else { return }
		if AutofillConsoleSession.current() != nil {
			Self.submissionBudget.resetAfterVerifiedUnlock()
			Self.manualInputObserved = false
		}
		isWatching = true

		// Tokens are kept because these are block observers.
		//
		// `removeObserver(self)` was never removing them: the block API registers an
		// opaque token as the observer, not `self`, so `stop()` left both observers live
		// and a later `start()` added a second pair. Two observers means `screenLocked()`
		// runs twice, and the second run cancels the attempt the first one started.
		let centre = DistributedNotificationCenter.default()
		observers.append(
			centre.addObserver(
				forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.screenLocked() }
			})
		observers.append(
			centre.addObserver(
				forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.screenUnlocked() }
			})

		// Wake is a workspace notification, not a distributed one, so it needs its own
		// centre. Both are observed: `didWake` is the machine, `screensDidWake` is the
		// displays, and which arrives first depends on how the Mac was woken — a lid, a
		// key press, or a Bluetooth mouse are not the same sequence.
		let workspace = NSWorkspace.shared.notificationCenter
		observers.append(
			workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.wokeUp(source: "didWake") }
			})
		observers.append(
			workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.wokeUp(source: "screensDidWake") }
			})
		observers.append(
			workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.wokeUp(source: "sessionActive") }
			})
		observers.append(
			workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.systemWillSleep() }
			})
		observers.append(
			workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
				[weak self] _ in
				MainActor.assumeIsolated { self?.displaysSlept() }
			})
		// External monitors often finish waking and reconfiguring seconds after `didWake`
		// / `screensDidWake`. Re-check wake state when screen topology changes.
		observers.append(
			NotificationCenter.default.addObserver(
				forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.screenParametersChanged() }
			})

		// The screen saver covers everything, so a lock reported while it runs must
		// not start a scan. Dismissing it starts one only if a password is required.
		observers.append(
			centre.addObserver(
				forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.screenSaverStarted() }
			})
		observers.append(
			centre.addObserver(
				forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.screenSaverStopped() }
			})

		// If Gaze starts (or restarts its watcher) while already locked, synchronize state
		// so Space/pointer retry and the unlock watchdog are live.
		if Self.screenIsLocked() {
			isLocked = true
			spaceMonitor.start()
			if !Self.displaysAreAsleep() {
				startUnlockWatchdog()
				watchPointerForRetry()
			}
		}

		Self.logger.notice("Watching for screen lock and wake.")
	}

	package func stop() {
		if let diagnosticID { LockScanDiagnostics.shared.cancel(for: diagnosticID) }
		submissionID = nil
		didSubmitPassword = false
		resetAttemptTiming()
		lastFacePixelBuffer = nil
		closedAttemptLogged = false
		attempt?.cancel()
		attempt = nil
		attemptID = nil
		unlockWatchdog?.cancel()
		unlockWatchdog = nil
		pointerRetry?.cancel()
		pointerRetry = nil
		wakeProbe?.cancel()
		wakeProbe = nil
		unlockRetryTask?.cancel()
		unlockRetryTask = nil
		submissionCheckTask?.cancel()
		submissionCheckTask = nil
		capsule.hide()
		LockScreenLight.shared.hide()
		isWatching = false
		isLocked = false
		lastWakeTrigger = nil
		lastSleepAt = nil
		clamshellClosedAtSleep = false
		screenSaverRunning = false
		screenSaverStartedAt = nil
		spaceMonitor.stop()
		for token in observers {
			DistributedNotificationCenter.default().removeObserver(token)
			NSWorkspace.shared.notificationCenter.removeObserver(token)
			NotificationCenter.default.removeObserver(token)
		}
		observers.removeAll()
	}

	// MARK: - Events

	internal func reconcileScreenSaverState(now: ContinuousClock.Instant = .now) {
		let running = LockWakePolicy.reconciledScreenSaverRunning(
			cachedRunning: screenSaverRunning,
			processRunning: Self.screenSaverIsRunning(),
			startedAt: screenSaverStartedAt,
			now: now)
		if screenSaverRunning && !running {
			Self.logger.notice("Cleared stale screen-saver state on wake/lock.")
			screenSaverStartedAt = nil
		}
		screenSaverRunning = running
	}

	private func screenLocked() {
		guard Self.screenIsLocked() else { return }
		unlockRetryTask?.cancel()
		unlockRetryTask = nil
		wakeProbe?.cancel()
		wakeProbe = nil
		// Warm the models now, while the camera is still off, so the first scan does
		// not stall loading them mid-loop. Off the main actor, in parallel with the
		// attempt below; warmUp reloads them if they were unloaded while idle.
		Task.detached(priority: .userInitiated) { [embedder = store.embedder] in
			embedder.warmUp()
			SpoofDetector.shared?.warmUp()
			IrisLocator.warmUp()
		}
		isLocked = true
		explainedStandDown = false
		if submissionID == nil && !didSubmitPassword {
			Self.manualInputObserved = false
		}
		spaceMonitor.start()
		closedAttemptLogged = false
		lastFacePixelBuffer = nil
		reconcileScreenSaverState()
		// The screen saver covers the panel, so a lock reported while it runs is
		// not a moment anyone can see or answer. Dismissing it starts the scan.
		guard !screenSaverRunning else {
			Self.logger.notice("Screen locked with the screen saver running; not scanning until it's dismissed.")
			return
		}
		// An idle Mac or Apple → Sleep locks as its display turns off. Scanning then
		// found a black screen and suspended camera. The display waking starts the scan.
		guard !Self.displaysAreAsleep() else {
			Self.logger.notice("Screen locked with the display off; waiting for it to wake.")
			return
		}
		beginAttempt(trigger: "Screen locked")
	}

	/// The system is entering Sleep (`Apple → Sleep`, lid close, or idle sleep).
	private func systemWillSleep() {
		tearDownForSleep(reason: "System entering sleep", endReason: "system-slept")
	}

	/// The display went dark mid-scan. Nobody can see the panel or answer it, so stop
	/// without counting anything; waking the display starts again.
	private func displaysSlept() {
		tearDownForSleep(reason: "Display turned off", endReason: "display-slept")
	}

	private func tearDownForSleep(reason: String, endReason: String) {
		lastSleepAt = .now
		if Self.isClamshellClosed() {
			clamshellClosedAtSleep = true
		}
		lastWakeTrigger = nil
		// Display/system sleep ends any prior typing or click stand-down so the next
		// wake gets a fresh scan. The one-shot submission budget is never reset here.
		Self.manualInputObserved = false
		wakeProbe?.cancel()
		wakeProbe = nil
		unlockWatchdog?.cancel()
		unlockWatchdog = nil
		pointerRetry?.cancel()
		pointerRetry = nil
		submissionCheckTask?.cancel()
		submissionCheckTask = nil
		// Nobody can see it, and the brightness it boosted should come back down.
		LockScreenLight.shared.hide()
		guard attempt != nil else { return }
		submissionID = nil
		didSubmitPassword = false
		Self.logger.notice("\(reason, privacy: .public) during a scan; stopping until it wakes.")
		logAttemptTiming(outcome: endReason)
		recordEndedWithoutGaze(.leftLocked, endReason: endReason)
		attempt?.cancel()
		attempt = nil
		attemptID = nil
		capsule.hide()
	}

	/// The screen saver started and covers everything. Stop like the display
	/// going dark: nobody can see the panel, so there is nothing to answer.
	private func screenSaverStarted() {
		screenSaverRunning = true
		screenSaverStartedAt = .now
		LockScreenLight.shared.hide()
		pointerRetry?.cancel()
		pointerRetry = nil
		guard attempt != nil else { return }
		submissionID = nil
		didSubmitPassword = false
		Self.logger.notice("Screen saver started; not scanning until it's dismissed.")
		logAttemptTiming(outcome: "screen-saver-started")
		recordEndedWithoutGaze(.leftLocked, endReason: "saver-started")
		attempt?.cancel()
		attempt = nil
		attemptID = nil
		capsule.hide()
	}

	/// The screen saver was dismissed. Scan only if a password is actually
	/// required now; otherwise the camera stays off.
	private func screenSaverStopped() {
		screenSaverRunning = false
		screenSaverStartedAt = nil
		guard Self.screenIsLocked() else { return }
		guard !Self.displaysAreAsleep() else { return }
		isLocked = true
		spaceMonitor.start()
		// The key or mouse that dismissed it must not count as input, same as wake.
		beginAttempt(trigger: "Screen saver dismissed", settle: Self.wakeSettle)
	}

	/// Whether the screen saver engine is running, in case its start
	/// notification was never delivered.
	internal static func screenSaverIsRunning() -> Bool {
		guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.ScreenSaver.Engine"
			|| !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty
		else { return false }
		return true
	}

	/// True only when *all* online displays are asleep (or no display is online).
	///
	/// On dual-display Macs where an external monitor is the main display, that monitor
	/// often reports asleep for seconds after wake while the built-in display is already
	/// awake and showing the lock screen. Checking every online display avoids dropping
	/// those wakes.
	internal static func displaysAreAsleep() -> Bool {
		var count: UInt32 = 0
		guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
			return CGDisplayIsAsleep(CGMainDisplayID()) != 0
		}
		guard count > 0 else { return true }
		var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
		guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
			return CGDisplayIsAsleep(CGMainDisplayID()) != 0
		}
		let states = displays.prefix(Int(count)).map { CGDisplayIsAsleep($0) != 0 }
		return LockWakePolicy.allDisplaysAsleep(displaySleepStates: states)
	}

	/// Display configuration changed (e.g. an external display finished waking or
	/// reconnecting after Sleep). If locked and idle with no scan yet since sleep,
	/// trigger the wake path.
	private func screenParametersChanged() {
		guard Self.screenIsLocked(), !Self.displaysAreAsleep() else { return }
		guard attempt == nil, submissionID == nil, !Self.manualInputObserved else { return }
		guard wakeProbe != nil || lastWakeTrigger == nil else { return }
		wokeUp(source: "screenParameters")
	}

	/// Probes briefly after a wake notification when displays are still turning on or
	/// `CGSSessionScreenIsLocked` has not finished updating yet. Bounded to ~3.25 s and
	/// cancelled immediately on sleep, unlock, or scan start.
	private func scheduleWakeProbe() {
		guard wakeProbe == nil else { return }
		wakeProbe = Task { [weak self] in
			for delay in LockWakePolicy.wakeProbeIntervals {
				do { try await Task.sleep(for: delay) }
				catch { return }
				guard let self, !Task.isCancelled, self.isWatching else { return }
				if Self.screenIsLocked() && !Self.displaysAreAsleep() {
					self.wakeProbe = nil
					self.wokeUp(source: "wake-probe")
					return
				}
			}
			guard let self, !Task.isCancelled else { return }
			self.wakeProbe = nil
		}
	}

	/// The Mac woke up. If it woke to a locked screen, look for a face.
	///
	/// This is the common case the app used to miss entirely. `com.apple.screenIsLocked`
	/// fires when the screen *becomes* locked — which, for a Mac put to Sleep or closed,
	/// happened before it went to sleep. Waking it posts no such notification, because
	/// nothing changed: it was locked then and it is locked now.
	private func wokeUp(source: String = "wake") {
		LockScreenLight.shared.restoreStrandedBrightnessIfNeeded()
		let locked = Self.screenIsLocked()
		let asleep = Self.displaysAreAsleep()
		guard locked && !asleep else {
			let recentlySlept = lastSleepAt.map { $0.duration(to: .now) < .seconds(30) } ?? false
			if source != "wake-probe", asleep || isLocked || recentlySlept {
				Self.logger.notice("Wake (\(source, privacy: .public)) deferred: locked=\(locked) displaysAsleep=\(asleep); probing briefly.")
				scheduleWakeProbe()
			}
			return
		}
		wakeProbe?.cancel()
		wakeProbe = nil

		isLocked = true
		spaceMonitor.start()
		startUnlockWatchdog()
		reconcileScreenSaverState()
		// The wake arrived while the screen saver still covers everything.
		guard !screenSaverRunning else {
			Self.logger.notice("Woke with the screen saver running; not scanning until it's dismissed.")
			return
		}

		// Waking posts more than one notification — the system wakes, then the displays
		// do — and both mean the same thing here. Suppress duplicates while an attempt
		// is running or just succeeded, but never drop `didWake` if an earlier
		// `screensDidWake` attempt already failed on a suspended camera.
		if LockWakePolicy.shouldDebounceWake(
			lastWakeAt: lastWakeTrigger,
			now: .now,
			attemptActive: attempt != nil,
			lastAttemptFailedCamera: cameraFailed
		) {
			return
		}
		lastWakeTrigger = .now

		// Only a genuine closed→open lid transition with no HID wake input uses the
		// shorter settle. Apple → Sleep with the lid open, desktop wakes, and keyboard/
		// mouse wakes keep the full settle (running in parallel with camera startup) so
		// wake clicks and key releases are never misread as password entry.
		let settleDecision = LockWakePolicy.settleDuration(
			clamshellWasClosed: clamshellClosedAtSleep,
			clamshellIsClosed: Self.isClamshellClosed(),
			secondsSinceKeyDown: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
			secondsSinceLeftClick: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown),
			secondsSinceRightClick: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .rightMouseDown),
			secondsSinceMouseMove: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
		)
		clamshellClosedAtSleep = false
		if settleDecision.isLidOpen {
			Self.logger.notice("Woke (\(source, privacy: .public)) by opening the lid with no recent input; using the shorter settle.")
		} else {
			Self.logger.notice("Woke (\(source, privacy: .public)) from sleep or input; using the full settle.")
		}
		beginAttempt(trigger: "Woke to a locked screen", settle: settleDecision.duration)
	}

	internal func screenUnlocked(retry: Int = 0) {
		unlockRetryTask?.cancel()
		unlockRetryTask = nil
		guard AutofillConsoleSession.current() != nil else {
			// The notification can arrive while the session still reports locked. Returning
			// here left the panel on the desktop and the camera running, so check again.
			if retry < 8 {
				unlockRetryTask = Task { [weak self] in
					do { try await Task.sleep(for: .milliseconds(250)) }
					catch { return }
					guard let self, !Task.isCancelled, self.isWatching else { return }
					self.screenUnlocked(retry: retry + 1)
				}
			} else if !Self.screenIsLocked() {
				Self.logger.notice("Unlocked into a session Gaze cannot verify; hiding the panel.")
				isLocked = false
				screenSaverRunning = false
				screenSaverStartedAt = nil
				clamshellClosedAtSleep = false
				lastSleepAt = nil
				Self.manualInputObserved = false
				spaceMonitor.stop()
				submissionID = nil
				didSubmitPassword = false
				logAttemptTiming(outcome: "unverified")
				recordEndedWithoutGaze(.openedAnotherWay)
				lastFacePixelBuffer = nil
				attempt?.cancel()
				attempt = nil
				attemptID = nil
				unlockWatchdog?.cancel()
				unlockWatchdog = nil
				pointerRetry?.cancel()
				pointerRetry = nil
				wakeProbe?.cancel()
				wakeProbe = nil
				submissionCheckTask?.cancel()
				submissionCheckTask = nil
				LockScreenLight.shared.hide()
				capsule.hide()
			}
			return
		}
		unlockWatchdog?.cancel()
		unlockWatchdog = nil
		pointerRetry?.cancel()
		pointerRetry = nil
		wakeProbe?.cancel()
		wakeProbe = nil
		submissionCheckTask?.cancel()
		submissionCheckTask = nil
		LockScreenLight.shared.hide()
		if let diagnosticID {
			if didSubmitPassword { LockScanDiagnostics.shared.record(.unlocked, for: diagnosticID) }
			else { LockScanDiagnostics.shared.finishScanning(for: diagnosticID) }
		}
		Self.submissionBudget.resetAfterVerifiedUnlock()
		Self.manualInputObserved = false
		submissionID = nil
		isLocked = false
		screenSaverRunning = false
		screenSaverStartedAt = nil
		clamshellClosedAtSleep = false
		lastSleepAt = nil
		spaceMonitor.stop()
		// Whatever unlocked the Mac, we are done. Cancelling releases the camera promptly
		// rather than leaving the indicator lit after the user has typed their password.
		attempt?.cancel()
		attempt = nil
		attemptID = nil

		guard didSubmitPassword else {
			// Unlocked by other means. Nothing to celebrate — just get out of the way.
			// macOS only unlocks after the account password or Touch ID, which is the
			// proof the lockout waits for, so it clears here as Face ID does after a
			// passcode. Before, it only cleared from Settings, and a locked-out Gaze
			// stayed silent on every lock screen after.
			if lockout.attemptsRemaining < LockoutManager.maxAttempts {
				lockout.clearAfterPasswordAuth()
			}
			logAttemptTiming(outcome: "other")
			recordEndedWithoutGaze(.openedAnotherWay)
			lastFacePixelBuffer = nil
			capsule.hide()
			return
		}
		let unlockDuration = attemptStartedAt.map(Self.seconds(since:))
		let steps = attemptSteps()
		logAttemptTiming(outcome: "unlocked")
		UnlockAttemptLog.shared.record(.unlocked, duration: unlockDuration, steps: steps,
			photo: lastFacePixelBuffer)
		lastFacePixelBuffer = nil
		closedAttemptLogged = false
		didSubmitPassword = false
		lockout.recordSuccess()
		// Ours, confirmed: this is the only moment learning may happen. The print is
		// the frame that matched, never a mask-path one — learned prints must stay in
		// the same space as the originals they are guarded against.
		if let pending = pendingLearnedPrint {
			store.learn(pending.print, for: pending.faceID)
		}
		pendingLearnedPrint = nil

		// The Mac agreed. Retract to the resting bar and let the padlock open there, which
		// is the last beat of the sequence and the only one the user is still looking at.
		capsule.update(phase: .unlocked)
		capsule.hide(after: Self.unlockAnimationDuration)
	}

	/// Asks the window server whether the screen is locked, right now.
	///
	/// The authoritative answer, unlike the `com.apple.screenIsLocked` notification, which
	/// tells us what was true when it was posted. Before replaying a password we need the
	/// current state, not a recent one.
	internal static func screenIsLocked() -> Bool {
		guard
			let session = CGSessionCopyCurrentDictionary() as? [String: Any],
			let locked = session["CGSSessionScreenIsLocked"] as? Bool
		else {
			// Unknown state: assume unlocked, because the failure we must avoid is typing
			// a password when we should not have.
			return false
		}
		return locked
	}
}
