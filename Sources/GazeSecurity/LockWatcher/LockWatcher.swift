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
	/// When the last wake trigger was honoured, so the pair of them counts as one.
	internal var lastWakeTrigger: Date?
	/// Block-observer tokens, so `stop()` can actually unregister them.
	internal var observers: [NSObjectProtocol] = []
	package private(set) var isWatching = false
	package private(set) var isLocked = false
	/// Whether the screen saver is currently running. While it covers the screen,
	/// scanning would light the camera with no panel visible.
	internal var screenSaverRunning = false
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

	/// Waking posts a system wake and a displays wake, moments apart. Both mean "look
	/// now", and honouring both would tear the camera down and rebuild it mid-attempt.
	private static let wakeDebounce: TimeInterval = 3.0
	/// A beat for the camera to actually be awake before the first frame is asked for.
	/// Opening it immediately after a wake returns a device that reports running and then
	/// delivers black frames, which reads to the recogniser as "nobody there". Shorter
	/// than it once was: the camera restarts itself after a wake now, so a device that
	/// is genuinely not ready gets a second chance without costing every unlock 700 ms.
	internal static let wakeSettle = Duration.milliseconds(450)

	/// Shorter settle after opening the lid. The full settle above exists so the key
	/// press or Escape that woke the Mac is taken before the input snapshot; opening
	/// the lid involves no key press, so there is nothing to let pass.
	private static let lidOpenSettle = Duration.milliseconds(150)

	/// Whether the lid is currently open. Desktops report no clamshell state and read
	/// false here, so they always keep the full settle.
	private static func lidOpenedRecently() -> Bool {
		let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
		guard service != IO_OBJECT_NULL else { return false }
		defer { IOObjectRelease(service) }
		guard let state = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool else { return false }
		return !state
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
		for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
			observers.append(
				workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.wokeUp() }
				})
		}

		observers.append(
			workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
				[weak self] _ in
				MainActor.assumeIsolated { self?.displaysSlept() }
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
		capsule.hide()
		LockScreenLight.shared.hide()
		isWatching = false
		lastWakeTrigger = nil
		screenSaverRunning = false
		spaceMonitor.stop()
		for token in observers {
			DistributedNotificationCenter.default().removeObserver(token)
			NSWorkspace.shared.notificationCenter.removeObserver(token)
		}
		observers.removeAll()
	}

	// MARK: - Events

	private func screenLocked() {
		guard Self.screenIsLocked() else { return }
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
		spaceMonitor.start()
		closedAttemptLogged = false
		lastFacePixelBuffer = nil
		// The screen saver covers the panel, so a lock reported while it runs is
		// not a moment anyone can see or answer. Dismissing it starts the scan.
		guard !screenSaverRunning else {
			Self.logger.notice("Screen locked with the screen saver running; not scanning until it's dismissed.")
			return
		}
		// An idle Mac usually locks as its display turns off. Scanning then found the
		// person sitting there and asked for a movement on a black screen, which timed out
		// and counted as a miss again and again. The display waking starts the scan instead.
		guard !Self.displaysAreAsleep() else {
			Self.logger.notice("Screen locked with the display off; waiting for it to wake.")
			return
		}
		beginAttempt(trigger: "Screen locked")
	}

	/// The display went dark mid-scan. Nobody can see the panel or answer it, so stop
	/// without counting anything; waking the display starts again.
	private func displaysSlept() {
		lastWakeTrigger = nil
		// Nobody can see it, and the brightness it boosted should come back down.
		LockScreenLight.shared.hide()
		pointerRetry?.cancel()
		pointerRetry = nil
		guard attempt != nil else { return }
		submissionID = nil
		didSubmitPassword = false
		Self.logger.notice("Display turned off during a scan; stopping until it wakes.")
		logAttemptTiming(outcome: "display-slept")
		recordEndedWithoutGaze(.leftLocked, endReason: "display-slept")
		attempt?.cancel()
		attempt = nil
		attemptID = nil
		capsule.hide()
	}

	/// The screen saver started and covers everything. Stop like the display
	/// going dark: nobody can see the panel, so there is nothing to answer.
	private func screenSaverStarted() {
		screenSaverRunning = true
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

	internal static func displaysAreAsleep() -> Bool {
		CGDisplayIsAsleep(CGMainDisplayID()) != 0
	}

	/// The Mac woke up. If it woke to a locked screen, look for a face.
	///
	/// This is the common case the app used to miss entirely. `com.apple.screenIsLocked`
	/// fires when the screen *becomes* locked — which, for a Mac that was closed and
	/// carried somewhere, happened before it went to sleep. Waking it posts no such
	/// notification, because nothing changed: it was locked then and it is locked now. So
	/// the most ordinary way anyone meets their lock screen — open the lid — was the one
	/// way Gaze never ran.
	private func wokeUp() {
		// The notification says the machine woke, not that the screen is locked. Ask the
		// window server rather than assuming, for the same reason the replay path does:
		// the failure to avoid is typing a password at a screen that is already open.
		guard Self.screenIsLocked() else { return }
		// The machine can wake before its display does; the display's own wake follows.
		guard !Self.displaysAreAsleep() else { return }

		// Waking posts more than one notification — the system wakes, then the displays
		// do — and both mean the same thing here. Without this, the second one cancels
		// the attempt the first one started and the camera is torn down and rebuilt.
		if let last = lastWakeTrigger, Date().timeIntervalSince(last) < Self.wakeDebounce {
			return
		}
		lastWakeTrigger = Date()

		isLocked = true
		spaceMonitor.start()
		// The wake arrived while the screen saver still covers everything.
		guard !screenSaverRunning else {
			Self.logger.notice("Woke with the screen saver running; not scanning until it's dismissed.")
			return
		}
		// Opening the lid involves no key press, so when the lid is open and nothing
		// was typed or clicked to wake the Mac, the shorter settle is enough before
		// the input snapshot is taken.
		let settle: Duration
		if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > 1.0,
			CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown) > 1.0 {
			settle = Self.lidOpenSettle
			Self.logger.notice("Woke with the lid open and no recent input; using the shorter settle.")
		} else {
			settle = Self.wakeSettle
			Self.logger.notice("Woke via key or mouse; using the full settle.")
		}
		beginAttempt(trigger: "Woke to a locked screen", settle: settle)
	}

	internal func screenUnlocked(retry: Int = 0) {
		guard AutofillConsoleSession.current() != nil else {
			// The notification can arrive while the session still reports locked. Returning
			// here left the panel on the desktop and the camera running, so check again.
			if retry < 8 {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
					MainActor.assumeIsolated { self?.screenUnlocked(retry: retry + 1) }
				}
			} else if !Self.screenIsLocked() {
				Self.logger.notice("Unlocked into a session Gaze cannot verify; hiding the panel.")
				StateBroadcast.post(.idle)
				GazeStatusBroadcast.screenUnlocked(by: .other)
				isLocked = false
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
				capsule.hide()
			}
			return
		}
		unlockWatchdog?.cancel()
		unlockWatchdog = nil
		pointerRetry?.cancel()
		pointerRetry = nil
		if let diagnosticID {
			if didSubmitPassword { LockScanDiagnostics.shared.record(.unlocked, for: diagnosticID) }
			else { LockScanDiagnostics.shared.finishScanning(for: diagnosticID) }
		}
		Self.submissionBudget.resetAfterVerifiedUnlock()
		Self.manualInputObserved = false
		submissionID = nil
		isLocked = false
		spaceMonitor.stop()
		StateBroadcast.post(.idle)
		GazeStatusBroadcast.screenUnlocked(by: didSubmitPassword ? .gaze : .other)
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
		StateBroadcast.post(.succeeded)

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
