import AppKit
import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import GazeLockScreen
import GazeRecognition
import os

extension LockWatcher {

	/// How long to keep looking after the screen locks before giving up.
	///
	/// Bounded on purpose: a camera that runs for the whole time the Mac sits locked is a
	/// battery and privacy problem. If the user isn't there in the first few seconds they
	/// have walked away, and they can wake the screen to try again.
	private static let searchWindow: TimeInterval = 12

	/// How long the face must keep matching, continuously, before the Mac unlocks.
	///
	/// Both a security and a feel decision. Recognition alone completes in under 200ms,
	/// which is fast enough that someone walking past the camera could unlock the machine
	/// before they had registered it happening — and fast enough that the animation reads
	/// as a glitch. Requiring the match to hold means a deliberate look unlocks and a
	/// glance does not.
	///
	/// 0.3 s: people who turn movements off chose speed. It still has to
	/// be a steady look, every frame of it still passes the photo and screen checks, and a
	/// face merely passing through the frame breaks the hold and starts it again.
	private static let requiredMatchDuration: TimeInterval = 0.3

	/// The hold when a movement challenge is configured. The challenge itself is the
	/// proof of presence, so the hold can be shorter and the unlock feel sooner — but
	/// only on that path. With the challenge off, the full hold above is all that stands
	/// between a match and the password, and it stays.
	private static let requiredMatchDurationWithChallenge: TimeInterval = 0.5

	/// How long a face must match before the movement is asked for. The full hold above
	/// still has to complete before the password goes in; this only starts the movement
	/// sooner, so the hold and the movement run at the same time.
	private static let challengeLead: Duration = .milliseconds(200)

	/// How long a face has to be looked at, without matching, before it counts as rejected.
	///
	/// Comfortably longer than `requiredMatchDuration`, or a face that needs a moment to be
	/// recognised would be turned away before it had the chance.
	private static let rejectAfter: TimeInterval = 4.0

	/// The pause between a rejection and the next attempt.
	private static let retryCooldown: TimeInterval = 2.0

	/// Below this overlap a match counts as a different physical subject, even for the
	/// same enrolled face, and restarts the hold rather than inheriting it.
	private static let subjectChangeOverlap: CGFloat = 0.2

	/// How far below the match threshold the tracked face may score while it is
	/// mid-movement the requested way, inside the interruption grace. Twice the turning
	/// allowance: a nod tips the face away from the enrolled prints more than a turn.
	private static let movementExcursionScoreDrop: Float = 0.30

	/// How long Follow the light shows its tick before the next prompt or the unlock.
	private static let lookConfirmation: Duration = .milliseconds(300)

	/// Cold cameras waking from sleep spend ~400 ms ramping auto-exposure and white balance.
	/// During this brief window, spoof-flagged frames are still skipped (fail-closed) without
	/// committing a hard lockout rejection, matching `SceneBrightness`'s exposure settle.
	private static let exposureSettleWindow: Duration = .milliseconds(450)

	/// Intersection over union of two Vision-normalized boxes. Same space on both sides
	/// is all it needs; the values never leave this comparison.
	private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
		let intersection = a.intersection(b)
		guard !intersection.isNull, !intersection.isEmpty else { return 0 }
		let union = a.width * a.height + b.width * b.height - intersection.width * intersection.height
		guard union > 0 else { return 0 }
		return (intersection.width * intersection.height) / union
	}

	// MARK: - Attempt

	internal func attemptUnlock(inputSnapshot: LockScreenInputSnapshot, identifier: UUID,
		prestarted: (camera: CameraController, started: Task<Void, Never>)? = nil) async {
		// Whatever ends the scan — an unlock, a rejection, the lockout, a camera that
		// died — the edge light goes out with it.
		SceneBrightness.reset()
		defer { LockScreenLight.shared.hide() }
		let telemetry = LockAttemptTelemetry(watcher: self, identifier: identifier)
		guard let session = await prepareAttemptSession(
			inputSnapshot: inputSnapshot, identifier: identifier, telemetry: telemetry, prestarted: prestarted)
		else { return }
		let camera = session.camera
		defer { camera.stop() }
		let cameraRequestedAt = session.requestedAt
		let inputMonitor = session.inputMonitor
		let evaluator = session.evaluator
		let challenge = session.challenge
		var challengeGate = session.challengeGate
		var freshFrames = RecognitionFrameGate()
		var evaluatedContinuity: UInt64?
		/// The enrolled face the current prompt was shown to. The match hold breaks while a
		/// movement rides out a brief interruption, so the hold alone can't say whose it was.
		var movementFaceID: UUID?
		/// While set, Follow the light's tick is showing and nothing new is presented.
		var lookConfirmedUntil: ContinuousClock.Instant?
		func resetMovementGuidance(reason: String) {
			challenge?.reset()
			lookConfirmedUntil = nil
			guard challengeGate.reset() else { return }
			telemetry.recordMovementWithdrawn(reason: reason)
		}

		/// When the current unbroken run of matching frames began.
		var matchingHold = RecognitionMatchHold()
		var rejectionHold = RecognitionRejectionHold()
		/// The last moment a usable (or dim-room blurred, full-size) face was in front of
		/// the camera. Monotonic so NTP clock jumps on wake from Sleep cannot skew timeouts.
		var lastFaceAt = ContinuousClock.now
		/// Set after a rejection, so the next try starts from a clean slate.
		var cooldownUntil: ContinuousClock.Instant?
		/// When the current run of too-blurred frames began, so a second of them
		/// can ask for light before the search gives up on the face.
		var blurredSince: ContinuousClock.Instant?
		/// Box of the last matched face. The next frame's candidates are tried in
		/// overlap order so the tracked subject is re-found without embedding the
		/// other faces when it is still there.
		var trackedBox: CGRect?

		func resetTracking(reason: String) {
			matchingHold.reset()
			rejectionHold.reset()
			trackedBox = nil
			resetMovementGuidance(reason: reason)
		}

		/// Whether a presented movement rides out this frame instead of being withdrawn
		/// (see `UnlockChallengeGate.interruptionGrace`). The holds still break, so the
		/// unlock needs a fresh continuous match afterwards; the tracked box is kept, so the
		/// face that comes back must be the same subject.
		func ridesOutInterruption(_ reason: String) -> Bool {
			guard challengeGate.tolerates(interruptionAt: .now) else { return false }
			matchingHold.reset()
			rejectionHold.reset()
			Self.logger.notice("Movement kept through a brief interruption. reason=\(reason, privacy: .public)")
			return true
		}

		/// Follow the light gets a brief tick when it passes, so the person knows it worked
		/// before the next prompt or the unlock.
		func confirmLookIfNeeded(_ action: LivenessChallenge.Action) {
			guard action.isLook else { return }
			telemetry.showLookConfirmed()
			lookConfirmedUntil = ContinuousClock.now.advanced(by: Self.lookConfirmation)
		}

		func consumeChallengeSample(_ sample: FaceSample, challenge: LivenessChallenge, resetHoldsOnInvalidation: Bool) -> Bool {
			let wasReturningToRest = challenge.isReturningToRest
			let consumption = challenge.consume(sample)
			if consumption.poseSourceInvalidated {
				if resetHoldsOnInvalidation {
					matchingHold.reset()
					rejectionHold.reset()
				}
				resetMovementGuidance(reason: "pose source changed")
				return false
			}
			if challenge.isReturningToRest && !wasReturningToRest {
				telemetry.recordMovementReturn(challenge: challenge)
			}
			return true
		}

		func completeChallengeAction(_ action: LivenessChallenge.Action, challenge: LivenessChallenge) -> Bool {
			challengeGate.completeAction()
			confirmLookIfNeeded(action)
			if !challengeGate.isVerified {
				challenge.next()
				return false
			}
			return true
		}

		func resetForNextAttempt() {
			challenge?.next()
			challengeGate.reset()
			matchingHold.reset()
			rejectionHold.reset()
			cooldownUntil = ContinuousClock.now.advanced(by: .milliseconds(Int(Self.retryCooldown * 1000)))
		}

		telemetry.logSearchStarted()

		// Keeps looking until the person gives up, not until a stopwatch runs out.
		//
		// This used to be a single 12-second window from the moment the screen locked, and
		// one failure ended the whole thing: after being rejected once you could stand in
		// front of the camera indefinitely and nothing would happen until you locked the
		// screen again. The window now measures *absence* — twelve seconds with nobody in
		// front of the camera means you walked away, and that is when it stops. A face that
		// is present and rejected simply gets another go.
		//
		// Still bounded, and by the thing that should bound it: six rejections and the
		// lockout takes over.
		let attemptDeadline = ContinuousClock.now.advanced(by: .seconds(60))
		var previousPoll = ContinuousClock.now
		while inputMonitor.requestIsCurrent(), ContinuousClock.now < attemptDeadline {
			let tick = telemetry.beginTick()
			defer { telemetry.endTick(start: tick.start, gapMs: tick.gapMs, frameID: camera.frameID) }
			let delay = RecognitionScanPacing.delay(since: previousPoll, now: .now)
			if delay > .zero {
				do { try await Task.sleep(for: delay) }
				catch { return }
			}
			previousPoll = .now
			guard inputMonitor.requestIsCurrent(), camera.state == .running,
				camera.boundDeviceID == inputMonitor.context.pinnedCamera else { return }
			switch freshFrames.observe(id: camera.frameID, capturedAt: camera.lastFrameCapturedAt, now: .now) {
			case .stalled:
				telemetry.recordCameraStalled(camera: camera, freshFrames: freshFrames)
				cameraFailed = true
				return
			case .waiting:
				// No fresh frame this poll. After several in a row the holds describe a
				// face that is no longer there, so both reset — well under the 1 s
				// stall timeout that ends the scan.
				telemetry.consecutiveWaits += 1
				if telemetry.consecutiveWaits >= 10 {
					matchingHold.reset()
					rejectionHold.reset()
				}
				continue
			case .fresh(let continuous):
				telemetry.consecutiveWaits = 0
				telemetry.recordFirstFrameIfNeeded(cameraRequestedAt: cameraRequestedAt, camera: camera)
				if !continuous { resetTracking(reason: "frame gap") }
			}

			if challengeGate.expired(at: .now) {
				telemetry.recordChallengeTimedOut(photo: camera.sample?.pixelBuffer, lookPasses: challenge?.lookPassLog)
				resetForNextAttempt()
				continue
			}

			telemetry.ticks += 1
			// The screen is the only lamp a locked Mac has. Checked before the face, since
			// in a dark enough room there is no face to find until the light is on.
			if Preferences.shared.screenGlowInDark, !LockScreenLight.shared.isShowing,
				SceneBrightness.isDark() {
				LockScreenLight.shared.show()
				Self.lightNeededAt = Date()
			}
			guard !camera.faceMissing, var sample = camera.sample else {
				telemetry.lastAbsence = camera.absence?.summary ?? "no sample"
				// Lost for a moment mid-movement: a nod can tip the face out of detection.
				// A second face in frame is never ridden out.
				let secondFace = if case .multipleFaces? = camera.absence { true } else { false }
				if !secondFace, ridesOutInterruption("face unavailable") { continue }
				// Face left the frame — both runs are broken and start again from zero.
				resetTracking(reason: "face unavailable")
				if lastFaceAt.duration(to: .now) >= .seconds(Self.searchWindow) { break }
				continue
			}
			lastFacePixelBuffer = sample.pixelBuffer

			// A beat after a rejection before looking again, so the panel has time to say
			// "not recognised" and the next attempt is not judged on the same frames.
			if let until = cooldownUntil {
				guard ContinuousClock.now >= until else { continue }
				cooldownUntil = nil
				telemetry.recordCooldownEnded()
			}

			// Every face in the frame is a candidate, largest first, with the tracked
			// subject reordered to the front: overlap re-finds it without embedding
			// the other faces when it is still there.
			var candidates = [sample] + sample.bystanders
			if let trackedBox {
				candidates.sort {
					Self.overlap($0.boundingBox, trackedBox) > Self.overlap($1.boundingBox, trackedBox)
				}
			}
			telemetry.recordFaceAndCandidateMetrics(candidates)
			let usable = candidates.filter { FrameQuality.rejection($0) == nil }
			guard !usable.isEmpty else {
				// Motion blur mid-movement is the movement, not a new attempt.
				if !ridesOutInterruption("frame quality") {
					matchingHold.reset()
					rejectionHold.reset()
					resetMovementGuidance(reason: "frame quality")
				}
				let qualityRejection = FrameQuality.rejection(sample)
				telemetry.recordQualityRejection(qualityRejection)
				if case .tooBlurred = qualityRejection {
					// A full-size face blurred by a dim room still counts as present while
					// the edge light warms up; tiny distant posters (.tooSmall) do not.
					lastFaceAt = .now
					let since = blurredSince ?? .now
					blurredSince = since
					// Only in a dim room: in daylight a blurred face is just movement.
					if Preferences.shared.screenGlowInDark, !LockScreenLight.shared.isShowing,
						since.duration(to: .now) >= .seconds(1),
						let brightness = SceneBrightness.current(), brightness < 0.25 {
						LockScreenLight.shared.show()
					}
				} else if lastFaceAt.duration(to: .now) >= .seconds(Self.searchWindow) {
					break
				}
				continue
			}
			lastFaceAt = .now
			blurredSince = nil

			let sampleFrameID = camera.frameID
			let sampleContinuity = camera.evidenceContinuity.revision
			if evaluatedContinuity != sampleContinuity {
				resetTracking(reason: "camera continuity")
				evaluatedContinuity = sampleContinuity
			}
			guard let sampleCapturedAt = camera.lastFrameCapturedAt else { continue }
			let settlingExposure = firstFrameAt.map { $0.duration(to: .now) < Self.exposureSettleWindow } ?? true
			let inferenceStarted = ContinuousClock.now
			var result = await evaluator.evaluate(usable[0], settlingExposure: settlingExposure)
			var frameBest = result.score
			var matchedSample: FaceSample? = result.matched ? usable[0] : nil
			// The tracked subject is tried first and the rest are skipped when it
			// matches, so a held look costs one embedding a frame. Otherwise every
			// usable face is tried until one matches; only a frame where none match
			// counts as a miss, so a stranger beside the owner never fails the frame.
			// Every later check (anti-spoof, movement) runs on the matched face.
			if matchedSample == nil {
				for candidate in usable.dropFirst() {
					let next = await evaluator.evaluate(candidate, settlingExposure: settlingExposure)
					frameBest = max(frameBest, next.score)
					if next.matched {
						result = next
						matchedSample = candidate
						break
					}
				}
			}
			// Candidates come from the same camera frame, so sampleFrameID captured
			// above is still correct after the swap.
			if let matchedSample { sample = matchedSample }
			telemetry.recordInferenceDuration(since: inferenceStarted)
			guard inputMonitor.requestIsCurrent(), camera.state == .running,
				camera.boundDeviceID == inputMonitor.context.pinnedCamera else { return }
			let evaluatedAt = ContinuousClock.now
			let age = sampleCapturedAt.duration(to: evaluatedAt)
			let continuityIntact = camera.evidenceContinuity.permits(sampleContinuity, at: evaluatedAt)
			guard continuityIntact, age <= CameraFrameLease.maximumAge else {
				if challengeGate.isPresented {
					telemetry.recordStaleInference(continuityIntact: continuityIntact, age: age,
						inferenceStarted: inferenceStarted, evaluatedAt: evaluatedAt)
				}
				resetTracking(reason: "stale inference")
				continue
			}
			telemetry.recordFrameBest(frameBest)
			guard result.matched, let face = result.face else {
				// A head turned for the requested movement scores below the match
				// threshold, so a near-miss on the tracked face feeds the challenge
				// instead of wiping it. Anything else keeps the rejection path below.
				let turningScoreFloor = store.embedder.matchThreshold - 0.15
				let trackedContinuity = trackedBox.map {
					Self.overlap(sample.boundingBox, $0) >= Self.subjectChangeOverlap
				}
				let isSameFaceTurning = result.comparedIdentity && result.failure == nil
					&& result.score >= turningScoreFloor && (trackedContinuity ?? true)
				if isSameFaceTurning, let challenge, challengeGate.isPresented, !challengeGate.isVerified {
					guard challengeGate.admits(frameID: sampleFrameID, capturedAt: sampleCapturedAt, now: .now)
					else { continue }
					telemetry.logMovementProgress(kind: "turning", challenge: challenge, score: result.score)
					challengeGate.resume()
					let action = challenge.action
					guard consumeChallengeSample(sample, challenge: challenge, resetHoldsOnInvalidation: true) else { continue }
					if challenge.isComplete { _ = completeChallengeAction(action, challenge: challenge) }
					continue
				}
				if isSameFaceTurning { continue }
				// Further below the match than a turn goes, but still the tracked face and still
				// mid-movement the requested way: a nod tips the face away from the enrolled
				// prints. These frames feed the outward half of the movement, inside the
				// interruption grace only. They can never complete it, since completion is the
				// return to the starting pose, where the face has to match again, and they never
				// count toward the match hold. A low score at rest is still a different person.
				let isTrackedFaceMoving = result.comparedIdentity && result.failure == nil
					&& result.score >= store.embedder.matchThreshold - Self.movementExcursionScoreDrop
					&& trackedContinuity == true
				if isTrackedFaceMoving, let challenge, challengeGate.isPresented, !challengeGate.isVerified,
					challenge.isMovingAsAsked(sample.pose), ridesOutInterruption("movement excursion") {
					guard challengeGate.admits(frameID: sampleFrameID, capturedAt: sampleCapturedAt, now: .now)
					else { continue }
					telemetry.logMovementProgress(kind: "excursion", challenge: challenge, score: result.score)
					_ = consumeChallengeSample(sample, challenge: challenge, resetHoldsOnInvalidation: false)
					continue
				}
				matchingHold.reset()
				if challengeGate.isPresented, let challenge {
					telemetry.recordMovementFailure(challenge: challenge, result: result, sample: sample)
				}
				resetMovementGuidance(reason: "identity mismatch")

				// Long enough looking at a face that is not yours to call it a rejection.
				// Comfortably longer than the match has to hold, or a real face would be
				// turned away before it had the chance to succeed.
				if rejectionHold.consume(capturedAt: sampleCapturedAt, required: .seconds(Self.rejectAfter)) {
					telemetry.recordUnknownFace(photo: sample.pixelBuffer, score: result.score)
					resetForNextAttempt()
				}
				continue
			}
			rejectionHold.reset()
			challengeGate.resume()

			if firstMatchAt == nil { firstMatchAt = .now }

			// Remember the matched frame for learning, but only a full-face match —
			// a mask-path print lives in the same space but describes half a face,
			// and learned prints must stay comparable with the originals.
			if !result.viaUpperFace, let matchedPrint = result.matchedPrint {
				pendingLearnedPrint = (matchedPrint, face.id)
			}

			if let decision = result.spoofDecision {
				// One frame the classifier doubts: skip it without counting it either way.
				// Only a frame that passes every check can complete the hold below.
				if case .suspect(let score) = decision {
					telemetry.recordSuspectFrame(score: score)
					matchingHold.reset()
					continue
				}
				if case .unavailable = decision {
					telemetry.recordAntiSpoofInferenceFailed()
					return
				}
				if case .spoof(let reason, let score) = decision {
					telemetry.recordSpoofRejected(photo: sample.pixelBuffer, reason: reason, score: score)
					await evaluator.resetSpoofCues()
					resetForNextAttempt()
					continue
				}
			}
			guard result.permitsMatchHold(requiresAntiSpoof: true) else {
				telemetry.recordMatchHoldBlocked()
				matchingHold.reset()
				challenge?.reset()
				challengeGate.reset()
				return
			}
			// A hold broken by an interruption the movement rode out still belongs to the
			// face the prompt was shown to.
			let heldFaceID = matchingHold.faceID ?? (challengeGate.isPresented ? movementFaceID : nil)
			if heldFaceID != face.id {
				resetMovementGuidance(reason: "identity changed")
			} else if let trackedBox,
				Self.overlap(sample.boundingBox, trackedBox) < Self.subjectChangeOverlap
			{
				// Same enrolled face, different physical subject: it must not inherit the hold.
				matchingHold.reset()
				resetMovementGuidance(reason: "subject changed")
			}
			trackedBox = sample.boundingBox
			let heldMatch = matchingHold.consume(faceID: face.id, now: sampleCapturedAt,
				required: inputMonitor.context.instantUnlock ? .zero : .seconds(inputMonitor.context.movementCount == .none
					? Self.requiredMatchDuration : Self.requiredMatchDurationWithChallenge))
			// Ask for the movement once the face has matched briefly, instead of after the
			// whole hold. The hold keeps counting while the person moves, and the final gate
			// below still needs the full continuous hold, the movement and anti-spoof, so
			// nothing gets easier: the two waits just overlap instead of adding up. The
			// prompt still only ever appears for a face that already matched.
			let readyToAsk = inputMonitor.context.movementCount != .none && matchingHold.consume(faceID: face.id,
				now: sampleCapturedAt, required: Self.challengeLead)
			if !challengeGate.isPresented && !challengeGate.isVerified {
				challenge?.prepareBaseline(sample)
			}
			guard heldMatch || readyToAsk || challengeGate.isPresented else { continue }

			// The movement challenge, if one was asked for.
			//
			// After the match and after anti-spoof, because there is no point asking a
			// stranger to blink — the demand is only meaningful once the face is already
			// accepted, and putting it earlier would show a prompt to anybody who walked
			// past. It is the last thing between recognition and the password.
			if let challenge, !challengeGate.isVerified {
				if !challengeGate.isPresented {
					guard challenge.isBaselineReady,
						lookConfirmedUntil.map({ ContinuousClock.now >= $0 }) ?? true else { continue }
					guard capsule.canPresentGuidance else {
						telemetry.recordGuidanceUnavailable()
						return
					}
					challengeGate.present(at: .now, frameID: sampleFrameID)
					movementFaceID = face.id
					telemetry.recordMovementPresented(challenge: challenge, gate: challengeGate)
					continue
				}
				guard challengeGate.admits(frameID: sampleFrameID, capturedAt: sampleCapturedAt, now: .now)
				else { continue }
				let action = challenge.action
				guard consumeChallengeSample(sample, challenge: challenge, resetHoldsOnInvalidation: true),
					challenge.isComplete else { continue }
				guard completeChallengeAction(action, challenge: challenge) else { continue }
				telemetry.recordMovementCompleted(challenge)
			}
			guard heldMatch, challengeGate.isVerified,
				lookConfirmedUntil.map({ ContinuousClock.now >= $0 }) ?? true else { continue }

			let evidenceIsCurrent = { inputMonitor.evidenceIsCurrent(camera: camera,
				sampleContinuity: sampleContinuity, sampleCapturedAt: sampleCapturedAt, challengeGate: challengeGate) }
			let proofStillCurrent = { inputMonitor.proofStillCurrent(camera: camera,
				sampleContinuity: sampleContinuity, sampleCapturedAt: sampleCapturedAt, challengeGate: challengeGate) }
			guard proofStillCurrent() else {
				Self.logger.notice("Proof became invalid before password submission: guidance=\(self.capsule.canPresentGuidance) running=\(camera.state == .running) verified=\(challengeGate.isVerified).")
				capsule.hide()
				return
			}
			guard UnlockExecutionPolicy.current.permitsPasswordSubmission else {
				telemetry.recordScanOnlyPassed(requiredActions: challengeGate.requiredActions)
				return
			}

			guard Self.submissionBudget.reserve() else { return }
			do {
				try KeystrokeUnlockBackend().submitPassword(if: proofStillCurrent, evidenceIsCurrent: evidenceIsCurrent)
			} catch {
				telemetry.recordSubmissionFailed(error)
				return
			}
			let receiptID = telemetry.recordSubmissionPending()
			scheduleSubmissionConfirmationCheck(receiptID: receiptID, identifier: identifier)
			return
		}

		guard !Task.isCancelled else { return }
		telemetry.finishSearch()
	}
}
