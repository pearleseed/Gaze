import AppKit
import Foundation
import GazeCamera
import GazeCore
import GazeLockScreen
import GazeRecognition
import IOKit
import IOKit.pwr_mgt
import os

extension LockWatcher {

	/// How long to wait for the Mac to actually unlock before giving up on it.
	private static let unlockGracePeriod: TimeInterval = 3.0

	/// Everything both triggers do. Shared so the two cannot drift apart.
	///
	/// - Parameter settle: how long to wait before opening the camera. Zero when the
	///   screen locks in front of us, because the hardware is already awake; a beat after
	///   a wake, because it is not — asking too early returns a camera that reports
	///   running and delivers black frames for the first second.
	internal func beginAttempt(trigger: String, settle: Duration = .zero) {
		// Reconcile screen-saver state in case didstart/didstop was missed across Sleep.
		reconcileScreenSaverState()
		guard !screenSaverRunning else {
			Self.logger.notice("\(trigger, privacy: .public) with the screen saver running; not scanning until it's dismissed.")
			return
		}
		// A wake can arrive without a prior lock notification, so warm here too, in
		// parallel with the camera start. Off the main actor; a no-op if already warm.
		Task.detached(priority: .userInitiated) { [embedder = store.embedder] in
			embedder.warmUp()
			SpoofDetector.shared?.warmUp()
			IrisLocator.warmUp()
		}
		guard UnlockExecutionPolicy.current.permitsScanning(passwordReplayEnabled: PasswordReplaySafety.isEnabled,
			keystrokeSelected: Preferences.shared.unlockBackend == .keystroke) else { return }
		guard submissionID == nil, Self.submissionBudget.maySubmit, !Self.manualInputObserved else {
			Self.logger.notice("\(trigger, privacy: .public) ignored: submitting=\(self.submissionID != nil) budget=\(Self.submissionBudget.maySubmit) typed=\(Self.manualInputObserved)")
			// Stood down only because of typing or a click: keep the notch live, so
			// moving the pointer into it can still ask for another look.
			if submissionID == nil, Self.submissionBudget.maySubmit, isLocked, attempt == nil {
				watchPointerForRetry()
			}
			return
		}
		guard attempt == nil else { return }
		guard store.isEnrolled else { return }
		guard Preferences.shared.unlockBackend != .keystroke || !PasswordVault.isStale else {
			Self.logger.notice("\(trigger, privacy: .public) with an out-of-date saved password; not looking.")
			explainStandDown("Your Mac password changed. Update it in Gaze.")
			return
		}
		// Paused means paused: no camera, no panel, no indicator light. Checked here
		// rather than inside the attempt so a pause costs nothing at all — the point of
		// the switch is that Gaze is not looking, and a green camera light that turns
		// itself off again would say otherwise.
		guard !Preferences.shared.isPaused else {
			Self.logger.notice("\(trigger, privacy: .public) while paused; not looking.")
			explainStandDown("Gaze is paused.")
			return
		}
		guard lockout.mayAttempt() else {
			Self.logger.notice("\(trigger, privacy: .public) while locked out; not looking.")
			explainStandDown("Too many tries. Unlock with your password.")
			return
		}
		if UnlockExecutionPolicy.current == .scanOnly {
			Self.logger.notice("Scan-only diagnostic started. No credential will be read or typed.")
		}

		Self.logger.notice("\(trigger, privacy: .public) — looking for a face.")
		pointerRetry?.cancel()
		pointerRetry = nil

		// A padlock, immediately. It is a statement about the Mac's state, not a claim
		// that the camera is looking at anyone — that distinction is why the compact
		// locked phase exists separately from scanning.
		didSubmitPassword = false
		pendingLearnedPrint = nil
		capsule.show(phase: .locked)
		startUnlockWatchdog()

		let identifier = UUID()
		attemptID = identifier
		diagnosticID = identifier
		resetAttemptTiming()
		attemptStartedAt = .now
		LockScanDiagnostics.shared.begin(identifier)
		attempt = Task {
			defer {
				IrisLocator.forgetFrame()
				LockScanDiagnostics.shared.finishScanning(for: identifier)
				if self.attemptID == identifier {
					self.attempt = nil
					self.attemptID = nil
				}
			}
			// A screen saver that asks for a password locks the session a moment before
			// it reports starting, so the lock alone raced it and the camera light came
			// on under the saver. Wait that moment out, with the camera still off.
			// Only an idle lock can be the screen saver's. A lock right after a key press or
			// click (Control-Command-Q, the menu, closing the lid) skips the wait, which was
			// adding 0.6 s before the panel opened on every manual lock.
			let idle = min(
				CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
				CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
				CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved))
			if trigger == "Screen locked", idle > 5 {
				try? await Task.sleep(for: .milliseconds(300))
				if Self.screenSaverIsRunning() { self.screenSaverRunning = true }
				guard !Task.isCancelled, !self.screenSaverRunning else {
					Self.logger.notice("Screen saver took over the lock; not scanning until it's dismissed.")
					return
				}
			}
			// If the last look needed the light a few minutes ago, the room is still dark:
			// light it straight away instead of waiting a second and a half to find out.
			if Preferences.shared.screenGlowInDark, let at = Self.lightNeededAt,
				Date().timeIntervalSince(at) < 15 * 60, !LockScreenLight.shared.isShowing {
				LockScreenLight.shared.show()
			}
			// Open the panel now, while the camera starts, rather than on its first frame:
			// the camera takes most of a second, and a panel that waited for it felt slow.
			self.capsule.update(phase: .scanning)
			// Keep the display awake while looking. The lock screen dims and sleeps the
			// display on its own short timer, which could cut a scan off mid-movement.
			// Held only for this attempt, so an ignored lock screen still sleeps.
			var displayAssertion = IOPMAssertionID(0)
			let holdsDisplay = IOPMAssertionCreateWithName(
				kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
				IOPMAssertionLevel(kIOPMAssertionLevelOn),
				"Gaze is checking for your face" as CFString,
				&displayAssertion) == kIOReturnSuccess
			defer { if holdsDisplay { IOPMAssertionRelease(displayAssertion) } }
			// The camera starts now, alongside the settle, instead of after it. Starting a
			// session takes about as long as the settle itself, so running them one after
			// the other cost every lid-open unlock roughly half a second. The frames that
			// arrive during the settle are the dark ones it exists to skip, and the scan
			// loop only begins after it, so nothing looks at them.
			var early: (camera: CameraController, started: Task<Void, Never>)?
			if settle > .zero {
				let allowExternal = Preferences.shared.allowExternalCamera
				let available = CameraDevice.candidates(allowExternal: allowExternal).map(\.uniqueID)
				if let pinned = self.store.unlockCamera(allowExternal: allowExternal, available: available)?.cameraID,
					!pinned.isEmpty {
					let camera = CameraController(accessScope: .lockScreen)
					early = (camera, Task { await camera.start(pinnedDeviceID: pinned) })
				}
				try? await Task.sleep(for: settle)
				guard !Task.isCancelled else {
					early?.camera.stop()
					return
				}
			}
			// Taken after the settle, so the key press or Escape that woke the Mac, or
			// came with opening the lid, does not read as someone typing a password.
			let inputSnapshot = LockScreenInputSnapshot.current()
			// A camera that fails right after a wake usually works a moment later once the
			// ISP / USB bus finishes resuming, so it gets two bounded restarts. The input
			// snapshot is kept, so a click or typing during an earlier try still stops it.
			let retryDelays: [Duration] = [.milliseconds(500), .seconds(1)]
			for retry in 0...retryDelays.count {
				self.cameraFailed = false
				await self.attemptUnlock(inputSnapshot: inputSnapshot, identifier: identifier,
					prestarted: retry == 0 ? early : nil)
				if retry == 0 { early = nil }
				guard self.cameraFailed, retry < retryDelays.count, !Task.isCancelled, self.isLocked,
					!Self.manualInputObserved, !Self.displaysAreAsleep() else { break }
				Self.logger.notice("Camera failed (try \(retry + 1)); restarting after a short settle.")
				do { try await Task.sleep(for: retryDelays[retry]) }
				catch { return }
				guard !Task.isCancelled, self.isLocked, !Self.manualInputObserved, !Self.displaysAreAsleep() else { return }
			}
			if !Task.isCancelled, self.isLocked { self.watchPointerForRetry() }
		}
	}

	/// Space on the lock screen means "look again". Stamped first, so the press never
	/// counts as typing even when a scan is already running; only a still screen with
	/// no scan in progress starts one.
	/// Shows why Gaze isn't scanning, briefly and once per lock, instead of doing nothing.
	private func explainStandDown(_ message: String) {
		guard isLocked, !explainedStandDown, !Self.displaysAreAsleep() else { return }
		explainedStandDown = true
		capsule.show(phase: .unavailable(message))
		capsule.hide(after: 2.5)
	}

	internal func handleSpaceKey() {
		lastSpaceAt = Date()
		spacePresses += 1
		reconcileScreenSaverState()
		// Space is an explicit "look again", so it lifts the stand-down that earlier
		// typing or a click caused for this lock. A password with a space in it is
		// unaffected: Gaze clears the field before it types.
		if Self.manualInputObserved, attempt == nil {
			Self.manualInputObserved = false
			Self.logger.notice("Space pressed after manual input; looking again.")
		}
		guard isLocked, !Self.displaysAreAsleep(), !screenSaverRunning, attempt == nil else {
			Self.logger.notice("Space ignored: locked=\(self.isLocked) asleep=\(Self.displaysAreAsleep()) saver=\(self.screenSaverRunning) scanning=\(self.attempt != nil)")
			return
		}
		beginAttempt(trigger: "Space pressed on a locked screen")
	}

	/// Moving the mouse or trackpad after a scan has ended starts a new one.
	///
	/// Clicks and key presses still stop Gaze for this lock (see `LockScreenInputGuard`),
	/// and after them plain movement no longer counts. Moving the pointer *into* the notch
	/// does: like Space, it is a deliberate "look again", so it lifts that stand-down. That
	/// is the way back when the panel went away before you were in front of the camera.
	/// Only an entry counts, so a pointer left parked at the notch does not loop scans.
	internal func watchPointerForRetry() {
		pointerRetry?.cancel()
		let moves = CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved)
		let startedInNotch = NotchMetrics.pointerIsInHoverZone()
		pointerRetry = Task { [weak self] in
			var wasInNotch = startedInNotch
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(250))
				guard let self, !Task.isCancelled, self.isLocked else { return }
				let inNotch = NotchMetrics.pointerIsInHoverZone()
				let enteredNotch = inNotch && !wasInNotch
				wasInNotch = inNotch
				guard !Self.displaysAreAsleep(), !self.screenSaverRunning, self.attempt == nil else { continue }
				if Self.manualInputObserved {
					guard enteredNotch else { continue }
					Self.manualInputObserved = false
					Self.logger.notice("Pointer entered the notch after manual input; looking again.")
				} else {
					guard enteredNotch
						|| CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved) != moves
					else { continue }
				}
				self.pointerRetry = nil
				self.beginAttempt(trigger: enteredNotch
					? "Pointer entered the notch on a locked screen" : "Pointer moved on a locked screen")
				return
			}
		}
	}

	/// Two unlocked readings a second apart end the attempt as if the notification had come.
	internal func startUnlockWatchdog() {
		unlockWatchdog?.cancel()
		unlockWatchdog = Task { [weak self] in
			var unlockedReadings = 0
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(1))
				guard let self, !Task.isCancelled, self.isLocked else { return }
				unlockedReadings = Self.screenIsLocked() ? 0 : unlockedReadings + 1
				if unlockedReadings >= 2 {
					Self.logger.notice("Screen is unlocked but no unlock notification was handled; tidying up.")
					self.screenUnlocked()
					return
				}
			}
		}
	}

	/// Unless nothing happens. A password can be refused, and a panel left showing a
	/// waiting state over a lock screen that never opened would insist something is
	/// still in flight. Withdraw it instead.
	internal func scheduleSubmissionConfirmationCheck(receiptID: UUID, identifier: UUID) {
		submissionCheckTask?.cancel()
		submissionCheckTask = Task { [weak self] in
			do { try await Task.sleep(for: .seconds(Self.unlockGracePeriod)) }
			catch { return }
			guard let self, !Task.isCancelled, self.isLocked, self.submissionID == receiptID else { return }
			self.submissionCheckTask = nil
			LockScanDiagnostics.shared.record(.submissionUnconfirmed, for: identifier)
			Self.logger.notice("Screen did not unlock after submitting; withdrawing.")
			self.submissionID = nil
			self.didSubmitPassword = false
			self.capsule.hide()
			// The face already passed, so the usual reason is a saved password that no
			// longer matches the account. Check once, off the main thread; if so, stop
			// typing it and don't count the face against the lockout.
			Task.detached(priority: .userInitiated) {
				let stillMatches = (try? PasswordVault.password()).flatMap { $0 }.map { PasswordVault.verify($0) } ?? true
				await MainActor.run {
					if stillMatches {
						self.lockout.recordFailure()
					} else {
						PasswordVault.isStale = true
						StalePasswordNotice.post()
						Self.logger.error("The saved password no longer matches this account; Gaze stops typing it until a new one is saved.")
					}
				}
			}
		}
	}

	/// Validates attempt prerequisites, warms up models, and starts or adopts the pinned camera.
	internal func prepareAttemptSession(
		inputSnapshot: LockScreenInputSnapshot,
		identifier: UUID,
		telemetry: LockAttemptTelemetry,
		prestarted: (camera: CameraController, started: Task<Void, Never>)?
	) async -> (camera: CameraController, requestedAt: ContinuousClock.Instant, inputMonitor: LockAttemptInputMonitor, evaluator: UnlockFrameEvaluator, challenge: LivenessChallenge?, challengeGate: UnlockChallengeGate)? {
		// Any early return below must not leave the early-started camera running.
		var adoptedPrestarted = false
		defer {
			if !adoptedPrestarted, let prestarted {
				prestarted.camera.stop()
				// Its start may still be in flight; stop again once it lands so a session
				// that finished starting after the first stop doesn't stay on.
				Task { @MainActor in
					await prestarted.started.value
					prestarted.camera.stop()
				}
			}
		}
		guard UnlockGuard.embedderBlocker() == nil, store.isEnrolled, !store.isCorrupted,
			let lockedSession = LockedConsoleSession.current() else { telemetry.report(.verificationUnavailable); return nil }
		// Only switched-on faces may unlock; a face turned off mid-attempt ends the attempt.
		let allowExternal = Preferences.shared.allowExternalCamera
		let available = CameraDevice.candidates(allowExternal: allowExternal).map(\.uniqueID)
		guard let choice = store.unlockCamera(allowExternal: allowExternal, available: available), !choice.cameraID.isEmpty else { telemetry.report(.cameraUnavailable); return nil }
		let movementCount = Preferences.shared.unlockMovementCount
		// First matching frame unlocks, when chosen for this movement count. Every frame
		// still passes the photo and screen check, and movements are still asked for.
		let instantUnlock = Preferences.shared.instantUnlock(for: movementCount)
		// Mask matching only runs alongside a movement challenge, so an upper-face
		// match is never the sole proof of presence. With the challenge off, the
		// setting does nothing at the lock screen rather than weakening anything.
		let maskUnlock = Preferences.shared.unlockWithMask && movementCount != .none
		let context = LockAttemptInputMonitor.Context(
			lockedSession: lockedSession, allowExternal: allowExternal, available: available,
			pinnedCamera: choice.cameraID, enrolledFaces: choice.faceIDs, movementCount: movementCount,
			maskUnlock: maskUnlock, instantUnlock: instantUnlock, entryEmbedder: Embedders.best().identifier)
		let inputMonitor = LockAttemptInputMonitor(watcher: self, identifier: identifier, inputSnapshot: inputSnapshot, context: context)
		guard inputMonitor.requestIsCurrent() else { capsule.hide(); return nil }
		let antiSpoof: AntiSpoofGate? = AntiSpoofGate(spoof: SpoofDetector.shared)
		if let antiSpoof, !antiSpoof.isActive {
			telemetry.recordAntiSpoofUnavailable()
			return nil
		}
		guard inputMonitor.requestIsCurrent() else { capsule.hide(); return nil }
		// The first recognition used to load both models mid-scan, stalling the loop for
		// over a second right after the first frame, which the stall check read as a dead
		// camera. They load here instead, while the camera is still starting.
		let embedder = store.embedder
		let warmUp = Task.detached(priority: .userInitiated) {
			embedder.warmUp()
			SpoofDetector.shared?.warmUp()
			IrisLocator.warmUp()
		}
		let camera = prestarted?.camera ?? CameraController(accessScope: .lockScreen)
		adoptedPrestarted = true
		let cameraRequestedAt = ContinuousClock.now
		if let prestarted {
			await prestarted.started.value
		} else {
			await camera.start(pinnedDeviceID: context.pinnedCamera)
		}
		await warmUp.value

		guard inputMonitor.requestIsCurrent() else {
			camera.stop()
			return nil
		}
		guard camera.state == .running, camera.boundDeviceID == context.pinnedCamera else {
			camera.stop()
			if inputMonitor.contextIsCurrent() {
				telemetry.report(.cameraUnavailable)
				cameraFailed = true
			}
			Self.logger.error("Camera unavailable: \(String(describing: camera.state), privacy: .public)")
			return nil
		}
		cameraRunningAt = .now
		// The panel drops as soon as the camera is on, not when its first frame arrives,
		// so it never lags a second or more behind the camera light.
		capsule.update(phase: .scanning)
		let evaluator = UnlockFrameEvaluator(embedder: store.embedder,
			faces: store.faces.filter { $0.isEnabled && context.enrolledFaces.contains($0.id) },
			antiSpoof: antiSpoof, allowsMaskUnlock: context.maskUnlock)
		// Under Reduce Motion there is no moving light: Follow the light is left out and
		// the other offered movements are asked for instead.
		let challenge: LivenessChallenge? = LivenessChallenge(
			allowsLook: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
		let challengeGate = UnlockChallengeGate(requiredActions: context.movementCount.rawValue)
		return (camera, cameraRequestedAt, inputMonitor, evaluator, challenge, challengeGate)
	}
}

/// Tracks attempt environment, Space-retry forgiveness, and manual-input interruption
/// during a single unlock attempt.
@MainActor
internal final class LockAttemptInputMonitor {

	struct Context {
		let lockedSession: LockedConsoleSession
		let allowExternal: Bool
		let available: [String]
		let pinnedCamera: String
		let enrolledFaces: [UUID]
		let movementCount: Preferences.UnlockMovementCount
		let maskUnlock: Bool
		let instantUnlock: Bool
		let entryEmbedder: String
	}

	private let watcher: LockWatcher
	private let identifier: UUID
	let context: Context
	private var inputGuard: LockScreenInputGuard
	// Baseline for the Space forgiveness below. Tracks the re-baseline, so a second
	// Space mid-scan is forgiven against the first one rather than the attempt start.
	private var spaceBaseline: LockScreenInputSnapshot
	private var spaceBaselinePresses: Int
	private let otherKeysBaseline: Int
	// When a single unexplained keyDown was first seen. The key counter moves the
	// instant a key goes down; the Space monitor's report arrives a run-loop turn
	// later, so the guard briefly waits for it instead of calling it typing.
	private var unexplainedKeySince: Date?

	init(watcher: LockWatcher, identifier: UUID, inputSnapshot: LockScreenInputSnapshot, context: Context) {
		self.watcher = watcher
		self.identifier = identifier
		self.context = context
		self.inputGuard = LockScreenInputGuard(initial: inputSnapshot)
		self.spaceBaseline = inputSnapshot
		self.spaceBaselinePresses = watcher.spacePresses
		self.otherKeysBaseline = watcher.spaceMonitor.otherKeyDowns
	}

	func contextIsCurrent() -> Bool {
		guard !Task.isCancelled, watcher.isLocked, !LockWatcher.manualInputObserved,
			LockedConsoleSession.current() == context.lockedSession,
			watcher.lockout.mayAttempt(), !Preferences.shared.isPaused,
			UnlockExecutionPolicy.current.permitsScanning(passwordReplayEnabled: PasswordReplaySafety.isEnabled,
				keystrokeSelected: Preferences.shared.unlockBackend == .keystroke),
			Preferences.shared.unlockMovementCount == context.movementCount,
			(Preferences.shared.unlockWithMask && Preferences.shared.unlockMovementCount != .none) == context.maskUnlock,
			Embedders.best().identifier == context.entryEmbedder,
			!watcher.store.isCorrupted, Preferences.shared.allowExternalCamera == context.allowExternal else { return false }
		guard let current = watcher.store.unlockCamera(allowExternal: context.allowExternal, available: context.available),
			current.cameraID == context.pinnedCamera, current.faceIDs == context.enrolledFaces else { return false }
		return true
	}

	func requestIsCurrent() -> Bool {
		guard contextIsCurrent() else { return false }
		let current = LockScreenInputSnapshot.current()
		guard inputGuard.permits(current) else {
			// Space the monitor saw is a retry request, not typing: forgive exactly
			// one keyDown within 300 ms of it and re-baseline. Anything else stops
			// Gaze as before.
			// With the monitor listening it sees every key on the keyboard, so typing
			// is any key that isn't Space. The system counter only backs it up, with
			// one press of slack because it can run ahead of the monitor's report.
			if watcher.spaceMonitor.isListening,
				watcher.spaceMonitor.otherKeyDowns == otherKeysBaseline,
				current.leftClicks == spaceBaseline.leftClicks,
				current.rightClicks == spaceBaseline.rightClicks,
				Int(current.keys &- spaceBaseline.keys) <= watcher.spacePresses - spaceBaselinePresses + 1 {
				watcher.lastSpaceAt = nil
				unexplainedKeySince = nil
				spaceBaseline = current
				spaceBaselinePresses = watcher.spacePresses
				inputGuard = LockScreenInputGuard(initial: current)
				return contextIsCurrent()
			}
			// Counted, not timed: every key since the baseline must be a Space the
			// monitor reported, and no click may have happened.
			let newKeys = Int(current.keys &- spaceBaseline.keys)
			let newSpaces = watcher.spacePresses - spaceBaselinePresses
			if newSpaces > 0, newKeys <= newSpaces,
				current.leftClicks == spaceBaseline.leftClicks,
				current.rightClicks == spaceBaseline.rightClicks {
				watcher.lastSpaceAt = nil
				unexplainedKeySince = nil
				spaceBaseline = current
				spaceBaselinePresses = watcher.spacePresses
				inputGuard = LockScreenInputGuard(initial: current)
				return contextIsCurrent()
			}
			if watcher.spaceMonitor.isListening,
				current.keys == spaceBaseline.keys &+ 1,
				current.leftClicks == spaceBaseline.leftClicks,
				current.rightClicks == spaceBaseline.rightClicks {
				let since = unexplainedKeySince ?? Date()
				unexplainedKeySince = since
				// Long enough for the report, far shorter than any match hold, so a
				// real keystroke still stops Gaze before it can unlock.
				if Date().timeIntervalSince(since) < 0.25 { return contextIsCurrent() }
			}
			if !LockWatcher.manualInputObserved {
				LockWatcher.logger.notice("Manual input observed (keys +\(current.keys &- self.spaceBaseline.keys), spaces +\(self.watcher.spacePresses - self.spaceBaselinePresses), other keys +\(self.watcher.spaceMonitor.otherKeyDowns - self.otherKeysBaseline), clicks +\(current.leftClicks &- self.spaceBaseline.leftClicks)/\(current.rightClicks &- self.spaceBaseline.rightClicks)); yielding to macOS authentication.")
			}
			LockWatcher.manualInputObserved = true
			LockScanDiagnostics.shared.record(.manualInput, for: identifier)
			watcher.capsule.hide()
			return false
		}
		return true
	}

	func evidenceIsCurrent(camera: CameraController, sampleContinuity: UInt64, sampleCapturedAt: ContinuousClock.Instant, challengeGate: UnlockChallengeGate) -> Bool {
		let now = ContinuousClock.now
		return contextIsCurrent() && challengeGate.isVerified && camera.state == .running
			&& camera.evidenceContinuity.permits(sampleContinuity, at: now)
			&& camera.boundDeviceID == context.pinnedCamera && watcher.capsule.canPresentGuidance
			&& sampleCapturedAt <= now && sampleCapturedAt.duration(to: now) <= CameraFrameLease.maximumAge
	}

	func proofStillCurrent(camera: CameraController, sampleContinuity: UInt64, sampleCapturedAt: ContinuousClock.Instant, challengeGate: UnlockChallengeGate) -> Bool {
		requestIsCurrent() && evidenceIsCurrent(camera: camera, sampleContinuity: sampleContinuity,
			sampleCapturedAt: sampleCapturedAt, challengeGate: challengeGate)
	}
}
