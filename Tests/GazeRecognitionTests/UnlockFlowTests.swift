import CoreGraphics
import CoreVideo
import Foundation
import GazeCamera
import GazeRecognition
import GazeSecurity
import Testing
import Vision

@Suite("Unlock Flow — Challenge Gate, Input Guard & Liveness", .serialized)
@MainActor
struct UnlockFlowTests {
	private func sample(
		_ challenge: LivenessChallenge,
		yaw: Double = 0,
		pitch: Double = 0,
		eyes: Float = 0.3,
		mouth: Float = 0.1,
		gaze: Double? = nil
	) {
		challenge.consume(yaw: yaw, pitch: pitch, eyes: eyes, mouth: mouth, gaze: gaze)
	}

	@Test func challengeGateResetAdmissionSequenceAndTimeout() {
		let now = ContinuousClock.now
		var gate = UnlockChallengeGate()
		let idleReset = gate.reset()
		#expect(!idleReset)
		gate.present(at: now, frameID: 1)
		let presentedReset = gate.reset()
		#expect(presentedReset)
		#expect(!gate.isPresented && !gate.isVerified)
		let repeatReset = gate.reset()
		#expect(!repeatReset)

		gate.completeAction()
		#expect(!gate.isVerified && gate.completedActions == 0)
		let unpromptedAdmit = gate.admits(frameID: 1, capturedAt: now, now: now)
		#expect(!unpromptedAdmit)

		gate.present(at: now, frameID: 1)
		for milliseconds in [-10, 0, 100, 349] {
			let time = now.advanced(by: .milliseconds(milliseconds))
			let admitted = gate.admits(frameID: 2, capturedAt: time, now: time)
			#expect(!admitted)
		}

		let response = now.advanced(by: .milliseconds(400))
		let reusePresFrame = gate.admits(frameID: 1, capturedAt: response, now: response)
		#expect(!reusePresFrame)
		let futureCap = gate.admits(frameID: 2, capturedAt: response, now: now)
		#expect(!futureCap)
		let staleCap = gate.admits(frameID: 2, capturedAt: response, now: response.advanced(by: .seconds(1)))
		#expect(!staleCap)
		let freshCap = gate.admits(frameID: 2, capturedAt: response, now: response)
		#expect(freshCap)
		let reusedEvidence = gate.admits(frameID: 2, capturedAt: response, now: response)
		#expect(!reusedEvidence)
		let duplicateTimestamp = gate.admits(frameID: 3, capturedAt: response, now: response)
		#expect(!duplicateTimestamp)

		gate.completeAction()
		#expect(gate.completedActions == 1 && !gate.isVerified)

		var interrupted = gate
		let interruptedReset = interrupted.reset()
		#expect(interruptedReset)
		#expect(interrupted.completedActions == 0 && !interrupted.isPresented)
		let withdrawnAdmit = interrupted.admits(frameID: 3, capturedAt: response, now: response)
		#expect(!withdrawnAdmit)

		gate.completeAction()
		#expect(gate.completedActions == 1)

		gate.present(at: response, frameID: 3)
		let second = response.advanced(by: .milliseconds(500))
		let secondAdmit = gate.admits(frameID: 4, capturedAt: second, now: second)
		#expect(secondAdmit)
		gate.completeAction()
		#expect(gate.isVerified)
		let postVerifyReset = gate.reset()
		#expect(postVerifyReset)
		#expect(!gate.isVerified && gate.completedActions == 0)

		gate.present(at: now, frameID: 1)
		#expect(gate.expired(at: now.advanced(by: .seconds(8))))
		#expect(gate.expired(at: now.advanced(by: .seconds(-1))))
		let late = now.advanced(by: .seconds(8))
		let lateAdmit = gate.admits(frameID: 5, capturedAt: late, now: late)
		#expect(!lateAdmit)
		gate.completeAction()
		#expect(!gate.isVerified)
	}

	@Test func lockScreenInputGuardCancelsIrreversiblyOnAnyInputChange() {
		let baseline = LockScreenInputSnapshot(keys: 100, leftClicks: 3, rightClicks: 4)
		for changed in [
			LockScreenInputSnapshot(keys: 101, leftClicks: 3, rightClicks: 4),
			LockScreenInputSnapshot(keys: 100, leftClicks: 4, rightClicks: 4),
			LockScreenInputSnapshot(keys: 100, leftClicks: 3, rightClicks: 5),
			LockScreenInputSnapshot(keys: 0, leftClicks: 3, rightClicks: 4),
		] {
			var input = LockScreenInputGuard(initial: baseline)
			let okBefore = input.permits(baseline)
			let okChanged = input.permits(changed)
			let okAfter = input.permits(baseline)
			#expect(okBefore)
			#expect(!okChanged)
			#expect(!okAfter)
		}
	}

	@Test func nonLookActionsExcursionReturnResetPrePromptAndWrongDirection() {
		let now = ContinuousClock.now
		for action in LivenessChallenge.Action.allCases where !action.isLook {
			let challenge = LivenessChallenge(action: action)
			let gazeRest: Double? = action.isLook ? 0.0 : nil
			let gazeOut: Double? = action == .lookLeft ? 0.2 : action == .lookRight ? -0.2 : nil
			for _ in 0..<10 { sample(challenge, gaze: gazeRest) }
			#expect(!challenge.isComplete)
			#expect(!challenge.isReturningToRest && challenge.guidancePrompt == action.prompt)

			let yaw: Double = action == .turnLeft ? 0.35 : action == .turnRight ? -0.35 : 0
			let pitch: Double = action == .nod ? 0.22 : 0
			for _ in 0..<(action.isLook ? 3 : 2) {
				sample(
					challenge,
					yaw: yaw,
					pitch: pitch,
					eyes: action == .blink ? 0.10 : 0.3,
					mouth: action == .openMouth ? 0.4 : 0.1,
					gaze: gazeOut
				)
			}
			#expect(!challenge.isComplete)
			#expect(challenge.isReturningToRest && challenge.guidanceSymbol == "viewfinder")
			#expect(challenge.guidanceHint.x == 0 && challenge.guidanceHint.y == 0 && !challenge.guidanceHint.pulses)

			sample(challenge, gaze: gazeRest)
			#expect(challenge.isComplete)
			#expect(!challenge.isReturningToRest)

			challenge.reset()
			#expect(!challenge.isComplete)
			#expect(!challenge.isReturningToRest && challenge.guidancePrompt == action.prompt)

			for _ in 0..<5 { sample(challenge, gaze: gazeRest) }
			challenge.consume(
				yaw: action == .turnLeft || action == .turnRight || action.isLook ? .nan : 0,
				pitch: action == .nod ? .nan : 0,
				eyes: action == .blink ? .nan : 0.3,
				mouth: action == .openMouth ? .nan : 0.1,
				gaze: action.isLook ? .nan : nil
			)
			for _ in 0..<2 { sample(challenge, yaw: yaw, pitch: pitch, eyes: 0.10, mouth: 0.4, gaze: gazeOut) }
			sample(challenge, gaze: gazeRest)
			#expect(!challenge.isComplete)

			let previous = challenge.action
			challenge.next()
			#expect(challenge.action != previous && !challenge.isComplete)
		}

		for action in [LivenessChallenge.Action.turnLeft, .turnRight, .nod] {
			let challenge = LivenessChallenge(action: action)
			for _ in 0..<4 { sample(challenge) }
			for _ in 0..<4 {
				sample(challenge, yaw: action == .turnLeft ? -0.4 : 0.4, pitch: -0.3)
			}
			sample(challenge)
			#expect(!challenge.isComplete)
			#expect(!challenge.isReturningToRest)
		}

		// Pre-prompt baseline preparation.
		for action in LivenessChallenge.Action.allCases where !action.isLook {
			let challenge = LivenessChallenge(action: action)
			let gazeRest: Double? = action.isLook ? 0.0 : nil
			let gazeOut: Double? = action == .lookLeft ? 0.2 : action == .lookRight ? -0.2 : nil
			for _ in 0..<2 { challenge.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1, gaze: gazeRest) }
			#expect(!challenge.isBaselineReady)
			challenge.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1, gaze: gazeRest)
			#expect(challenge.isBaselineReady && !challenge.isComplete)

			var prompt = UnlockChallengeGate()
			prompt.present(at: now, frameID: 100)
			let tooEarly = prompt.admits(
				frameID: 101,
				capturedAt: now.advanced(by: .milliseconds(100)),
				now: now.advanced(by: .milliseconds(100))
			)
			#expect(!tooEarly)

			let yaw: Double = action == .turnLeft ? 0.35 : action == .turnRight ? -0.35 : 0
			let pitch: Double = action == .nod ? 0.22 : 0
			for index in 0..<(action.isLook ? 3 : 2) {
				let captured = now.advanced(by: .milliseconds(400 + 100 * index))
				let admitted = prompt.admits(frameID: UInt64(102 + index), capturedAt: captured, now: captured)
				#expect(admitted)
				sample(
					challenge,
					yaw: yaw,
					pitch: pitch,
					eyes: action == .blink ? 0.1 : 0.3,
					mouth: action == .openMouth ? 0.4 : 0.1,
					gaze: gazeOut
				)
			}
			#expect(!challenge.isComplete)
			sample(challenge, gaze: gazeRest)
			#expect(challenge.isComplete)
			prompt.completeAction()
			#expect(!prompt.isVerified && prompt.completedActions == 1)

			challenge.reset()
			#expect(!challenge.isBaselineReady && !challenge.isComplete)

			for _ in 0..<3 { challenge.prepareBaseline(yaw: yaw, pitch: pitch, eyes: 0.1, mouth: 0.4) }
			for _ in 0..<3 { challenge.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1, gaze: gazeRest) }
			#expect(!challenge.isComplete)

			challenge.prepareBaseline(
				yaw: action == .turnLeft || action == .turnRight || action.isLook ? .nan : 0,
				pitch: action == .nod ? .nan : 0,
				eyes: action == .blink ? .nan : 0.3,
				mouth: action == .openMouth ? .nan : 0.1,
				gaze: action.isLook ? .nan : nil
			)
			#expect(!challenge.isBaselineReady)
		}
	}

	@Test func followTheLightPursuitAnglesFallbacksAndLeadIn() {
		#expect(LivenessChallenge.lookTargetPosition(elapsed: 0) == 0)
		#expect(LivenessChallenge.lookTargetPosition(elapsed: 0.65) == 1)
		#expect(LivenessChallenge.lookTargetPosition(elapsed: 1.25) == 0)

		func pursue(
			_ action: LivenessChallenge.Action,
			seconds: Double = 2.1,
			angle: Double? = nil,
			gaze: (Double) -> Double?,
			gazeY: (Double) -> Double? = { _ in nil },
			yaw: (Double) -> Double = { _ in 0 }
		) -> LivenessChallenge {
			let challenge = LivenessChallenge(action: action)
			var now = 100.0
			challenge.clock = { now }
			challenge.lookAngleOverride = angle ?? (action == .lookRight ? 0 : .pi)
			for _ in 0..<3 { challenge.consume(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1, gaze: 0.0, gazeY: 0.0) }
			let start = now
			while now - start < seconds, !challenge.isComplete {
				now += 1.0 / 30
				let t = now - start
				challenge.consume(yaw: yaw(t), pitch: 0, eyes: 0.3, mouth: 0.1, gaze: gaze(t), gazeY: gazeY(t))
			}
			return challenge
		}

		let followed = pursue(.lookRight) { t in -0.1 * LivenessChallenge.lookTargetPosition(elapsed: t) + 0.005 * sin(t * 40) }
		#expect(followed.guidancePrompt == "Follow the light with your eyes" || followed.isComplete)
		#expect(followed.isComplete)

		let followedLeft = pursue(.lookLeft) { t in 0.1 * LivenessChallenge.lookTargetPosition(elapsed: t) }
		#expect(followedLeft.isComplete)

		let still = pursue(.lookRight) { _ in 0 }
		#expect(!still.isComplete)

		let wrongWay = pursue(.lookRight) { t in 0.1 * LivenessChallenge.lookTargetPosition(elapsed: t) }
		#expect(!wrongWay.isComplete)

		let turned = pursue(
			.lookRight,
			gaze: { t in -0.1 * LivenessChallenge.lookTargetPosition(elapsed: t) },
			yaw: { t in t > 0.2 ? 0.26 : 0 }
		)
		#expect(!turned.isComplete)

		let tooSmall = pursue(.lookRight) { t in -0.02 * LivenessChallenge.lookTargetPosition(elapsed: t) }
		#expect(!tooSmall.isComplete)

		let r = { (t: Double) in LivenessChallenge.lookTargetPosition(elapsed: t) }
		let up = pursue(.lookRight, angle: .pi / 2, gaze: { _ in 0 }, gazeY: { t in 0.06 * r(t) })
		#expect(up.isComplete)

		let diagonal = pursue(.lookRight, angle: .pi * 5 / 4, gaze: { t in 0.07 * r(t) }, gazeY: { t in -0.035 * r(t) })
		#expect(diagonal.isComplete)

		let sideways = pursue(.lookRight, angle: .pi / 2, gaze: { t in -0.1 * r(t) }, gazeY: { _ in 0 })
		#expect(!sideways.isComplete)

		let noVertical = pursue(.lookRight, angle: .pi / 2, gaze: { _ in 0 })
		#expect(!noVertical.isComplete)

		let a1 = LivenessChallenge.lookAngle(cycle: 0, seed: 42)
		let a2 = LivenessChallenge.lookAngle(cycle: 1, seed: 42)
		#expect(a1 != a2 && (0..<(2 * Double.pi)).contains(a1))
		#expect(LivenessChallenge.lookAngle(cycle: 3, seed: 7) == LivenessChallenge.lookAngle(cycle: 3, seed: 7))

		let untracked = LivenessChallenge(action: .lookLeft)
		for _ in 0..<14 { untracked.consume(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1) }
		#expect(untracked.action == .lookLeft)
		untracked.consume(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1)
		#expect(!untracked.action.isLook)

		// Lead-in behavior.
		var time = 50.0
		let leadInChallenge = LivenessChallenge(action: .lookRight)
		leadInChallenge.clock = { time }
		LivenessChallenge.lookOrigin = nil
		LivenessChallenge.lookOverlayWaiting = true
		LivenessChallenge.lookLeadInUntil = time + LivenessChallenge.lookLeadIn
		defer {
			LivenessChallenge.lookOrigin = nil
			LivenessChallenge.lookOverlayWaiting = false
			LivenessChallenge.lookLeadInUntil = nil
		}
		for _ in 0..<3 { leadInChallenge.consume(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1, gaze: 0, gazeY: 0) }
		time += 0.5
		leadInChallenge.consume(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1, gaze: 0, gazeY: 0)
		#expect(LivenessChallenge.lookOrigin == nil && LivenessChallenge.lookOverlayWaiting)
		time += 0.4
		leadInChallenge.consume(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1, gaze: 0, gazeY: 0)
		#expect(LivenessChallenge.lookOrigin == time && !LivenessChallenge.lookOverlayWaiting)
	}

	@Test func poseDiagnosticsBlinkNodAcceptanceAndInterruptionGrace() throws {
		for action in [LivenessChallenge.Action.turnLeft, .turnRight, .nod] {
			let measured = LivenessChallenge(action: action)
			#expect(measured.poseMeasurement(yaw: 0.2, pitch: -0.1) == nil)
			for _ in 0..<3 { measured.prepareBaseline(yaw: 0.2, pitch: -0.1, eyes: 0.3, mouth: 0.1) }
			let yaw = action == .turnLeft ? 0.55 : action == .turnRight ? -0.15 : 0.2
			let pitch = action == .nod ? 0.12 : -0.1
			let measurement = try #require(measured.poseMeasurement(yaw: yaw, pitch: pitch))
			let expectedOffset = action == .turnLeft ? 0.35 : action == .turnRight ? -0.35 : 0.22
			#expect(abs(measurement.offset - expectedOffset) < 0.000001)
			#expect(!measured.isReturningToRest && !measured.isComplete)
			#expect(measured.poseMeasurement(yaw: .nan, pitch: pitch) == nil)
			for _ in 0..<2 { sample(measured, yaw: yaw, pitch: pitch) }
			#expect(measured.isReturningToRest && !measured.isComplete)
			let returned = try #require(measured.poseMeasurement(yaw: 0.2, pitch: -0.1))
			#expect(returned.offset == 0 && returned.returnTolerance == measurement.returnTolerance)
			sample(measured, yaw: 0.2, pitch: -0.1)
			#expect(measured.isComplete)
			measured.reset()
			#expect(measured.poseMeasurement(yaw: yaw, pitch: pitch) == nil)
		}

		let blink = LivenessChallenge(action: .blink)
		for _ in 0..<4 { sample(blink, eyes: 0.1) }
		sample(blink)
		#expect(!blink.isComplete)

		let narrow = LivenessChallenge(action: .blink)
		for _ in 0..<3 { sample(narrow, eyes: 0.14) }
		sample(narrow, eyes: 0.05)
		#expect(narrow.isReturningToRest)
		sample(narrow, eyes: 0.13)
		#expect(narrow.isComplete)

		// Nod acceptance.
		let gentle = LivenessChallenge(action: .nod)
		for _ in 0..<3 { gentle.prepareBaseline(yaw: 0, pitch: 0.05, eyes: 0.3, mouth: 0.1) }
		for pitch in [0.09, 0.15, 0.225, 0.225] { sample(gentle, pitch: pitch) }
		#expect(gentle.isReturningToRest && !gentle.isComplete)
		sample(gentle, pitch: 0.13)
		#expect(!gentle.isComplete)
		sample(gentle, pitch: 0.09)
		#expect(gentle.isComplete)

		let dip = LivenessChallenge(action: .nod)
		for _ in 0..<3 { dip.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1) }
		for pitch in [0.05, 0.10, 0.10, 0.04, 0] { sample(dip, pitch: pitch) }
		#expect(!dip.isReturningToRest && !dip.isComplete)

		let blip = LivenessChallenge(action: .nod)
		for _ in 0..<3 { blip.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1) }
		for pitch in [0.2, 0, 0.2, 0] { sample(blip, pitch: pitch) }
		#expect(!blip.isComplete)

		let moving = LivenessChallenge(action: .nod)
		#expect(!moving.isMovingAsAsked(FacePose(yaw: 0, pitch: 0.2, roll: 0)))
		for _ in 0..<3 { moving.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1) }
		#expect(moving.isMovingAsAsked(FacePose(yaw: 0, pitch: 0.10, roll: 0)))
		#expect(!moving.isMovingAsAsked(FacePose(yaw: 0, pitch: 0.03, roll: 0)))
		#expect(!moving.isMovingAsAsked(FacePose(yaw: 0, pitch: -0.15, roll: 0)))
		#expect(!moving.isMovingAsAsked(FacePose(yaw: 0, pitch: 0.15, roll: 0, pitchSource: .landmarkEstimate)))

		let turning = LivenessChallenge(action: .turnRight)
		for _ in 0..<3 { turning.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1) }
		#expect(
			turning.isMovingAsAsked(FacePose(yaw: -0.2, pitch: 0, roll: 0))
				&& !turning.isMovingAsAsked(FacePose(yaw: 0.2, pitch: 0, roll: 0))
		)

		let blinking = LivenessChallenge(action: .blink)
		for _ in 0..<3 { blinking.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1) }
		#expect(!blinking.isMovingAsAsked(FacePose(yaw: 0, pitch: 0.3, roll: 0)))

		// Movement interruption grace.
		let start = ContinuousClock.now
		func at(_ milliseconds: Int) -> ContinuousClock.Instant { start.advanced(by: .milliseconds(milliseconds)) }
		var gate = UnlockChallengeGate(requiredActions: 1)
		let t0 = gate.tolerates(interruptionAt: at(0))
		#expect(!t0)
		gate.present(at: at(0), frameID: 1)
		let t500 = gate.tolerates(interruptionAt: at(500))
		#expect(t500)
		let t1200 = gate.tolerates(interruptionAt: at(1_200))
		#expect(t1200)
		let t1350 = gate.tolerates(interruptionAt: at(1_350))
		#expect(!t1350)
		gate.resume()
		let t1400 = gate.tolerates(interruptionAt: at(1_400))
		#expect(t1400)
		#expect(gate.isPresented && gate.completedActions == 0)
		let admitted = gate.admits(frameID: 2, capturedAt: at(1_500), now: at(1_500))
		#expect(admitted)
		gate.completeAction()
		let t1600 = gate.tolerates(interruptionAt: at(1_600))
		#expect(gate.isVerified && !t1600)

		var late = UnlockChallengeGate(requiredActions: 1)
		late.present(at: at(0), frameID: 1)
		let t8000 = late.tolerates(interruptionAt: at(8_000))
		#expect(!t8000)
		let lateReset = late.reset()
		let t100 = late.tolerates(interruptionAt: at(100))
		#expect(lateReset && !t100)
	}

	@Test func injectablePupilProvidersSwitchFarLookWithoutRealPixels() async throws {
		let sample = try await Task.detached(priority: .userInitiated) { () throws -> FaceSample in
			var pixelBuffer: CVPixelBuffer?
			let status = CVPixelBufferCreate(
				kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
			)
			#expect(status == kCVReturnSuccess)
			let buffer = try #require(pixelBuffer)
			let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
			let face = VNFaceObservation(boundingBox: box)
			let request = VNDetectFaceLandmarksRequest()
			request.inputFaceObservations = [face]
			try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
			let landmarks = try #require(request.results?.first?.landmarks)
			return FaceSample(
				landmarks: landmarks,
				boundingBox: box,
				pose: .zero,
				quality: 0.8,
				hasQualityMeasurement: true,
				pixelBuffer: buffer
			)
		}.value

		let challenge = LivenessChallenge(action: .lookRight)
		var gazeProviderCalled = false
		challenge.eyeWidthProvider = { _ in LivenessChallenge.lookMinEyeWidth - 4 }
		challenge.pupilGazeProvider = { _ in
			gazeProviderCalled = true
			return nil
		}
		challenge.prepareBaseline(sample)
		#expect(!challenge.action.isLook, "too-narrow eye width switches away from Follow the light")
		#expect(!gazeProviderCalled, "switched non-look action skips pupil gaze lookup")
	}
}
