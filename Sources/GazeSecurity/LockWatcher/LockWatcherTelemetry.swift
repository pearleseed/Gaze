import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import GazeLockScreen
import GazeRecognition
import os

extension LockWatcher {

	/// Clears all per-attempt timing and movement metadata fields.
	internal func resetAttemptTiming() {
		attemptStartedAt = nil
		cameraRunningAt = nil
		firstFrameAt = nil
		firstMatchAt = nil
		passwordSubmittedAt = nil
		movementPresentedAt = nil
		movementDuration = nil
		movementPrompt = nil
		movementLookPasses = nil
	}

	/// The lock ended without Gaze doing it: someone got in another way, or the
	/// display went dark first. Filed once per lock, even with no face frame.
	internal func recordEndedWithoutGaze(_ result: UnlockAttempt.Result, endReason: String? = nil) {
		guard !closedAttemptLogged else { return }
		closedAttemptLogged = true
		UnlockAttemptLog.shared.record(result, photo: lastFacePixelBuffer, endReason: endReason)
	}

	/// One timing line per attempt, when it ends. Measurement only: nothing here
	/// is read by any branch, so unlock behaviour is identical either way.
	internal func logAttemptTiming(outcome: String) {
		guard let start = attemptStartedAt else { return }
		func ms(_ instant: ContinuousClock.Instant?) -> String {
			guard let instant else { return "-" }
			let parts = start.duration(to: instant).components
			let whole: Int64 = parts.seconds * 1_000
			let fraction: Int64 = parts.attoseconds / 1_000_000_000_000_000
			return String(whole + fraction) + "ms"
		}
		let line = "outcome=\(outcome) camera=\(ms(self.cameraRunningAt)) firstFrame=\(ms(self.firstFrameAt))"
			+ " firstMatch=\(ms(self.firstMatchAt)) submitted=\(ms(self.passwordSubmittedAt))"
		Self.logger.notice("timing attempt ended \(line, privacy: .public)")
		resetAttemptTiming()
	}

	/// The unlock split into its stages, for the Unlock Attempts list.
	internal func attemptSteps() -> UnlockAttempt.Steps? {
		guard let start = attemptStartedAt else { return nil }
		func between(_ a: ContinuousClock.Instant?, _ b: ContinuousClock.Instant?) -> TimeInterval? {
			guard let a, let b, a <= b else { return nil }
			let parts = a.duration(to: b).components
			return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
		}
		return UnlockAttempt.Steps(
			camera: between(start, cameraRunningAt),
			recognise: between(cameraRunningAt, firstMatchAt),
			check: between(firstMatchAt, passwordSubmittedAt),
			macOS: between(passwordSubmittedAt, .now),
			movement: movementDuration,
			movementPrompt: movementPrompt,
			lookPasses: movementLookPasses)
	}

	internal static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
		let parts = start.duration(to: .now).components
		return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
	}
}

/// Captures timing, render diagnostics, and attempt outcome telemetry for a single
/// unlock scan without affecting scan control flow.
@MainActor
internal final class LockAttemptTelemetry {

	private let watcher: LockWatcher
	private let identifier: UUID

	// Opt-in render timing (GAZE_RENDER_DIAGNOSTICS=1). Measurement and logging only:
	// no branch below reads these values, so unlock behaviour is identical either way.
	// drawableWaitMs stays 0: this loop never acquires a drawable; the field exists
	// so windows correlate with the renderer's drawable-wait counters.
	private let renderDiagnostics = RenderTiming.enabled
	private let renderAttempt: String
	private var renderTiming: RenderTiming
	private var renderPhase = "locked"
	private let renderClockStart = ContinuousClock.now
	private var renderPreviousTick: ContinuousClock.Instant?
	private var tickCapsuleMs = 0.0
	private var tickInferenceMs = 0.0

	// Counters, so "nobody in front of the camera" can say what it actually saw.
	//
	// That message was the only thing this loop reported on failure, and it is a
	// conclusion rather than an observation — it reads as "you walked away" when the
	// truth might be a camera delivering black frames, a face found and discarded by
	// the quality gate every time, or two faces in shot. Those need different fixes
	// and looked identical from outside.
	private var shownAt: Date?
	var ticks = 0
	private var framesWithFace = 0
	private var qualityRejects = 0
	var lastAbsence = "none"
	/// The highest score any frame reached this search.
	///
	/// Without it a search can see a face on dozens of frames and report no number at
	/// all, because a score is only logged once a rejection is *committed* — after
	/// `rejectAfter` seconds of continuous presence. Frames that came and went before
	/// that scored silently. "withFace=36" and "withFace=0" then look like the same
	/// fault when one is a camera problem and the other is a matching problem.
	private var bestScore: Float = 0
	/// Which of the two quality rejections fired, and how close the frames came.
	///
	/// The counts say which gate to move; the extremes say how far. A largest-seen face
	/// of 0.17 against a 0.18 floor is a threshold that is barely wrong; 0.04 is a
	/// bounding box being measured in the wrong space.
	private var tooSmall = 0
	private var tooBlurred = 0
	private var largestFace: CGFloat = 0
	private var bestQuality: Float = 0
	/// The most recent frame-quality rejection this scan, so a search that ends
	/// without unlocking can say why. Measurement only.
	private var lastRejection: FrameQuality.Rejection?
	/// Whether this scan already filed an attempt record, so the search-end
	/// fallback does not file a second one.
	private var recordedAttempt = false
	/// Matched frames the classifier doubted (`.suspect`) this scan. They never
	/// count toward the match hold; a scan that ends buried in them files a
	/// suspect-heavy reason instead of a generic one.
	private var suspectFrames = 0
	/// Consecutive polls with no fresh frame. Past a few the holds are stale,
	/// well before the stall timeout fires, so both reset.
	var consecutiveWaits = 0

	init(watcher: LockWatcher, identifier: UUID) {
		self.watcher = watcher
		self.identifier = identifier
		let shortID = String(identifier.uuidString.prefix(8))
		self.renderAttempt = shortID
		self.renderTiming = RenderTiming(attemptID: shortID)
	}

	func report(_ outcome: LockScanDiagnostics.Outcome) {
		LockScanDiagnostics.shared.record(outcome, for: identifier)
	}

	private func renderMs(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
		let parts = from.duration(to: to).components
		return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
	}

	func beginTick() -> (start: ContinuousClock.Instant, gapMs: Double) {
		let tickStart = ContinuousClock.now
		let tickGapMs = renderDiagnostics ? renderPreviousTick.map { renderMs($0, tickStart) } ?? 0 : 0
		if renderDiagnostics { renderPreviousTick = tickStart }
		tickCapsuleMs = 0
		tickInferenceMs = 0
		return (tickStart, tickGapMs)
	}

	func endTick(start: ContinuousClock.Instant, gapMs: Double, frameID: UInt64) {
		if renderDiagnostics {
			let tickStartMs = renderMs(renderClockStart, start)
			if let window = renderTiming.record(tick: ticks, frameID: frameID,
				phase: renderPhase, tickStartMs: tickStartMs, capsuleUpdateMs: tickCapsuleMs,
				callbackGapMs: gapMs, drawableWaitMs: 0, inferenceMs: tickInferenceMs) {
				LockWatcher.renderTimingLogger.notice("\(window, privacy: .public)")
			}
		}
	}

	func recordInferenceDuration(since started: ContinuousClock.Instant) {
		if renderDiagnostics { tickInferenceMs = renderMs(started, ContinuousClock.now) }
	}

	func updateCapsule(_ name: String, _ phase: NotchCapsuleModel.Phase) {
		guard renderDiagnostics else { watcher.capsule.update(phase: phase); return }
		let started = ContinuousClock.now
		watcher.capsule.update(phase: phase)
		tickCapsuleMs += renderMs(started, ContinuousClock.now)
		renderPhase = name
	}

	func logSearchStarted() {
		LockWatcher.logger.notice(
			"""
			Search starting. embedder=\(self.watcher.store.embedder.identifier, privacy: .public) \
			threshold=\(self.watcher.store.embedder.matchThreshold) faces=\(self.watcher.store.faces.count)
			""")
	}

	func recordAntiSpoofUnavailable() {
		report(.verificationUnavailable)
		LockWatcher.logger.error("Anti-spoof protection was requested but its model is unavailable. Refusing password submission.")
		watcher.capsule.update(phase: .unavailable("Gaze can’t check faces right now."))
	}

	func recordAntiSpoofInferenceFailed() {
		report(.verificationUnavailable)
		LockWatcher.logger.error("Anti-spoof inference failed; refusing password submission.")
		updateCapsule("unavailable", .unavailable("Gaze can’t check faces right now."))
	}

	func recordMatchHoldBlocked() {
		report(.verificationUnavailable)
		updateCapsule("unavailable", .unavailable("Gaze can’t check faces right now."))
	}

	func recordGuidanceUnavailable() {
		report(.verificationUnavailable)
		LockWatcher.logger.error("Guidance panel is unavailable; refusing a hidden movement challenge.")
		watcher.capsule.hide()
	}

	func showLookConfirmed() {
		updateCapsule("lookDone", .challenge(prompt: NotchCapsuleModel.Phase.movementDoneCaption,
			symbol: NotchCapsuleModel.Phase.movementDoneSymbol, hintX: 0, hintY: 0, pulses: false))
	}

	func logMovementProgress(kind: String, challenge: LivenessChallenge, score: Float) {
		LockWatcher.logger.notice("Movement progress from \(kind, privacy: .public) frame; action=\(challenge.action.prompt, privacy: .public) score=\(score) returning=\(challenge.isReturningToRest).")
	}

	func recordCameraStalled(camera: CameraController, freshFrames: RecognitionFrameGate) {
		report(freshFrames.hasReceivedFrame ? .cameraStalled : .firstFrameTimeout)
		let stage = freshFrames.hasReceivedFrame ? "running stream" : "first frame"
		LockWatcher.logger.error("Camera timed out at \(stage, privacy: .public); analyzed=\(camera.analyzedFrames) expired=\(camera.expiredFrames). No password submitted.")
		updateCapsule("unavailable", .unavailable("The camera isn’t responding."))
	}

	func recordFirstFrameIfNeeded(cameraRequestedAt: ContinuousClock.Instant, camera: CameraController) {
		guard shownAt == nil else { return }
		report(.scanning)
		watcher.firstFrameAt = .now
		let elapsed = cameraRequestedAt.duration(to: .now).components
		let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
		LockWatcher.logger.notice("First fresh camera frame ready after \(milliseconds)ms; analyzed=\(camera.analyzedFrames) expired=\(camera.expiredFrames).")
		updateCapsule("scanning", .scanning)
		shownAt = Date()
	}

	func recordCooldownEnded() {
		report(.scanning)
		updateCapsule("scanning", .scanning)
	}

	func recordFaceAndCandidateMetrics(_ candidates: [FaceSample]) {
		framesWithFace += 1
		for candidate in candidates {
			largestFace = max(largestFace, candidate.boundingBox.height)
			bestQuality = max(bestQuality, candidate.quality)
		}
	}

	func recordQualityRejection(_ qualityRejection: FrameQuality.Rejection?) {
		qualityRejects += 1
		lastRejection = qualityRejection
		switch qualityRejection {
		case .tooSmall: tooSmall += 1
		case .tooBlurred: tooBlurred += 1
		default: break
		}
	}

	func recordStaleInference(continuityIntact: Bool, age: Duration, inferenceStarted: ContinuousClock.Instant, evaluatedAt: ContinuousClock.Instant) {
		let duration = inferenceStarted.duration(to: evaluatedAt).components
		let milliseconds = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
		LockWatcher.logger.notice("Movement evidence invalidated: continuityIntact=\(continuityIntact) expired=\(age > CameraFrameLease.maximumAge) inferenceMs=\(milliseconds).")
	}

	func recordFrameBest(_ frameBest: Float) {
		bestScore = max(bestScore, frameBest)
	}

	func recordSuspectFrame(score: Float) {
		LockWatcher.logger.notice("Frame skipped: the photo classifier flagged it (\(String(format: "%.3f", score), privacy: .public)).")
		suspectFrames += 1
	}

	func recordMovementWithdrawn(reason: String) {
		report(.scanning)
		updateCapsule("retry", .challenge(prompt: "Face the camera to retry", symbol: "viewfinder",
			hintX: 0, hintY: 0, pulses: false))
		LockWatcher.logger.notice("Movement guidance withdrawn; reacquiring face. reason=\(reason, privacy: .public)")
	}

	func recordMovementReturn(challenge: LivenessChallenge) {
		let hint = challenge.guidanceHint
		updateCapsule("return", .challenge(prompt: challenge.guidancePrompt,
			symbol: challenge.guidanceSymbol, hintX: hint.x, hintY: hint.y, pulses: hint.pulses,
			isReturningToRest: true))
		LockWatcher.logger.notice("Requested movement observed; waiting for return to rest. action=\(challenge.action.prompt, privacy: .public)")
	}

	func recordMovementFailure(challenge: LivenessChallenge, result: UnlockFrameEvaluator.Result, sample: FaceSample) {
		let pose = challenge.poseMeasurement(yaw: sample.pose.yaw, pitch: sample.pose.pitch,
			yawSource: sample.pose.yawSource, pitchSource: sample.pose.pitchSource)
		LockScanDiagnostics.shared.recordMovementFailure(.init(action: challenge.action.prompt,
			returning: challenge.isReturningToRest, comparedIdentity: result.comparedIdentity,
			score: result.score, threshold: watcher.store.embedder.matchThreshold,
			poseOffset: pose?.offset, poseTarget: pose?.target, returnTolerance: pose?.returnTolerance),
			for: identifier)
		let failure = result.failure?.rawValue ?? "belowThreshold"
		if renderDiagnostics {
			renderTiming.lastIdentity = "\(failure) score=\(result.score) compared=\(result.comparedIdentity)"
		}
		let identityAttempt = renderDiagnostics ? " attempt=\(renderAttempt)" : ""
		LockWatcher.logger.notice("Movement identity check failed; action=\(challenge.action.prompt, privacy: .public) compared=\(result.comparedIdentity) failure=\(failure, privacy: .public) score=\(result.score) returning=\(challenge.isReturningToRest)\(identityAttempt, privacy: .public). No movement proof retained.")
	}

	func recordMovementPresented(challenge: LivenessChallenge, gate: UnlockChallengeGate) {
		watcher.movementPresentedAt = .now
		report(.movement)
		let hint = challenge.guidanceHint
		// Outward prompts carry the gate's progress in two-movement mode ("· 1 of 2"),
		// so the second prompt reads as progress rather than a reset. The return cue
		// below stays bare: the animated return is deliberately captionless.
		let outwardPrompt = NotchCapsuleModel.Phase.outwardPrompt(challenge.guidancePrompt,
			completedActions: gate.completedActions, requiredActions: gate.requiredActions)
		updateCapsule("challenge", .challenge(
			prompt: outwardPrompt,
			symbol: challenge.guidanceSymbol,
			hintX: hint.x, hintY: hint.y, pulses: hint.pulses))
		if renderDiagnostics { renderTiming.lastPrompt = challenge.action.prompt }
		let promptAttempt = renderDiagnostics ? " attempt=\(renderAttempt)" : ""
		LockWatcher.logger.notice("Movement prompt presented; action=\(challenge.action.prompt, privacy: .public); requiring fresh response \(gate.completedActions + 1) of \(gate.requiredActions)\(promptAttempt, privacy: .public).")
	}

	func recordMovementCompleted(_ challenge: LivenessChallenge) {
		if let presented = watcher.movementPresentedAt {
			watcher.movementDuration = LockWatcher.seconds(since: presented)
			watcher.movementPrompt = challenge.action.prompt
			watcher.movementLookPasses = challenge.lookPassLog
		}
	}

	func recordChallengeTimedOut(photo: CVPixelBuffer?, lookPasses: [String]?) {
		// Not counted toward the lockout: an unanswered movement is someone who
		// looked away or walked off, not a face that failed to match.
		LockWatcher.logger.notice("Challenge not answered in time; ending this attempt.")
		recordAttemptRejection(diagnostic: .challengeExpired, result: .notRecognised,
			reason: .movementTimedOut, photo: photo, steps: UnlockAttempt.Steps(lookPasses: lookPasses),
			countsTowardLockout: false, capsuleName: "notRecognised", capsulePhase: .notRecognised)
	}

	func recordUnknownFace(photo: CVPixelBuffer?, score: Float) {
		recordAttemptRejection(diagnostic: .notRecognized, result: .unknownFace,
			reason: .differentPerson, photo: photo, countsTowardLockout: true,
			capsuleName: "notRecognised", capsulePhase: .notRecognised)
		LockWatcher.logger.notice("Not recognised (score \(score)); will try again.")
	}

	func recordSpoofRejected(photo: CVPixelBuffer?, reason: String, score: Float) {
		// A spoof (matches the face but fails anti-spoof) is a rejection like any
		// other: shake the panel, count it toward lockout, and cool down before
		// the next look — otherwise it silently retried and nothing on screen
		// ever said no.
		LockWatcher.logger.notice("Match rejected by anti-spoof: \(reason, privacy: .public) (\(String(format: "%.3f", score), privacy: .public)).")
		recordAttemptRejection(diagnostic: .spoofRejected, result: .spoofRejected,
			reason: .photoOrScreen, photo: photo, countsTowardLockout: true,
			capsuleName: "spoofRejected", capsulePhase: .spoofRejected)
	}

	private func recordAttemptRejection(
		diagnostic: LockScanDiagnostics.Outcome,
		result: UnlockAttempt.Result,
		reason: UnlockAttempt.Reason,
		photo: CVPixelBuffer?,
		steps: UnlockAttempt.Steps? = nil,
		countsTowardLockout: Bool,
		capsuleName: String,
		capsulePhase: NotchCapsuleModel.Phase
	) {
		report(diagnostic)
		if countsTowardLockout {
			watcher.lockout.recordFailure()
		}
		UnlockAttemptLog.shared.record(result,
			steps: steps,
			photo: photo, reason: reason,
			bestScore: bestScore, threshold: watcher.store.embedder.matchThreshold,
			framesWithFace: framesWithFace, qualityRejects: qualityRejects,
			consecutiveFailures: watcher.lockout.consecutiveFailures,
			attemptsRemaining: watcher.lockout.attemptsRemaining)
		recordedAttempt = true
		updateCapsule(capsuleName, capsulePhase)
	}

	func recordScanOnlyPassed(requiredActions: Int) {
		report(.scanOnlyPassed)
		LockWatcher.logger.notice("Scan-only diagnostic passed: identity, configured anti-spoof and \(requiredActions) movement response(s) verified. No credential was read or typed; unlock manually.")
		watcher.capsule.hide(after: 0.8)
	}

	func recordSubmissionFailed(_ error: Error) {
		report(.submissionStopped)
		watcher.didSubmitPassword = false
		// The face matched; typing failed. Not a failed face, so not counted.
		updateCapsule("unavailable", .unavailable("Couldn’t type your password. Use it to unlock."))
		LockWatcher.logger.error("Unlock failed: \(error.localizedDescription)")
	}

	func recordSubmissionPending() -> UUID {
		watcher.didSubmitPassword = true
		watcher.passwordSubmittedAt = .now
		report(.submissionPending)
		let receiptID = UUID()
		watcher.submissionID = receiptID
		// Waiting, neutrally: the padlock stays closed with "Waiting for macOS" until the
		// Mac confirms the unlock. No tick and no opening padlock before then — either
		// would announce an outcome the login window has not reported yet.
		updateCapsule("pending", .pending)
		return receiptID
	}

	func finishSearch() {
		if LockScanDiagnostics.shared.outcome?.isScanning == true { report(.ended) }

		// Rejections are counted where they happen, one per attempt, so there is nothing to
		// record here — the loop ended because the person left or because the lockout took
		// over, and neither is a new failure. Counting one here as well meant walking away
		// cost an attempt.
		LockWatcher.logger.notice(
			"""
			Search ended. ticks=\(self.ticks) withFace=\(self.framesWithFace) \
			qualityRejected=\(self.qualityRejects) (small=\(self.tooSmall) blurred=\(self.tooBlurred)) suspect=\(self.suspectFrames) \
			largestFace=\(self.largestFace) bestQuality=\(self.bestQuality) best=\(self.bestScore) \
			waits=\(self.consecutiveWaits) attemptsRemaining=\(self.watcher.lockout.attemptsRemaining) \
		lastAbsence=\(self.lastAbsence, privacy: .public)
		""")
		// The scan gave up without unlocking and nothing else filed it: say why, from
		// the most recent frame-quality rejection, so the attempt is explainable.
		if !recordedAttempt, !watcher.didSubmitPassword {
			// A face that was seen clearly but never matched gets no reason: nothing
			// in the frame explains it, and guessing would mislead.
			let reason: UnlockAttempt.Reason?
			if suspectFrames >= UnlockFrameEvaluator.classifierFireFrames {
				reason = .photoOrScreen
			} else if framesWithFace == 0 {
				reason = .noFace
			} else {
				switch lastRejection {
				case .tooSmall: reason = .tooFar
				case .tooBlurred: reason = .tooDark
				case .invalidMeasurements, nil: reason = nil
				}
			}
			UnlockAttemptLog.shared.record(.notRecognised, photo: watcher.lastFacePixelBuffer, reason: reason,
				bestScore: bestScore, threshold: watcher.store.embedder.matchThreshold,
				framesWithFace: framesWithFace, qualityRejects: qualityRejects,
				consecutiveFailures: watcher.lockout.consecutiveFailures,
				attemptsRemaining: watcher.lockout.attemptsRemaining, endReason: "gave-up")
		}

		// Back to the padlock rather than vanishing — the Mac is still locked, and the
		// indicator should keep saying so.
		if watcher.isLocked {
			watcher.capsule.update(phase: .locked)
		}
	}
}
