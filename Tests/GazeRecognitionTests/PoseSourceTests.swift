import CoreGraphics
import Foundation
import GazeCamera
import GazeRecognition
import GazeSecurity
import Testing

@Suite("Pose Source Provenance & Axis Isolation")
@MainActor
struct PoseSourceTests {
	private func prepare(
		_ challenge: LivenessChallenge,
		yaw: Double = 0,
		pitch: Double = 0,
		yawSource: FacePose.AxisSource = .vision,
		pitchSource: FacePose.AxisSource = .vision,
		eyes: Float? = 0.3,
		mouth: Float? = 0.1
	) {
		challenge.prepareBaseline(
			yaw: yaw,
			pitch: pitch,
			yawSource: yawSource,
			pitchSource: pitchSource,
			eyes: eyes,
			mouth: mouth
		)
	}

	@discardableResult
	private func feed(
		_ challenge: LivenessChallenge,
		yaw: Double = 0,
		pitch: Double = 0,
		yawSource: FacePose.AxisSource = .vision,
		pitchSource: FacePose.AxisSource = .vision,
		eyes: Float? = 0.3,
		mouth: Float? = 0.1
	) -> LivenessChallenge.ConsumeResult {
		challenge.consume(
			yaw: yaw,
			pitch: pitch,
			yawSource: yawSource,
			pitchSource: pitchSource,
			eyes: eyes,
			mouth: mouth
		)
	}

	@Test func resolvedSelectionAndMissingLandmarks() {
		#expect(UnlockChallengeGate.defaultRequiredActions == 2)

		let estimate = FacePose(
			yaw: 0.22,
			pitch: 0.10,
			roll: 0.01,
			yawSource: .landmarkEstimate,
			pitchSource: .landmarkEstimate,
			rollSource: .landmarkEstimate
		)
		let both = FacePose.resolved(visionYaw: 0.05, visionPitch: -0.02, visionRoll: 0.0, estimate: estimate)
		#expect(both.yaw == 0.05 && both.yawSource == .vision)
		#expect(both.pitch == -0.02 && both.pitchSource == .vision)
		#expect(both.roll == 0.0 && both.rollSource == .vision)

		let mixed = FacePose.resolved(visionYaw: 0.05, visionPitch: nil, visionRoll: nil, estimate: estimate)
		#expect(mixed.yaw == 0.05 && mixed.yawSource == .vision)
		#expect(mixed.pitch == 0.10 && mixed.pitchSource == .landmarkEstimate)
		#expect(mixed.roll == 0.01 && mixed.rollSource == .landmarkEstimate)

		let missing = FacePose.resolved(
			visionYaw: nil,
			visionPitch: 0.03,
			visionRoll: nil,
			estimate: FacePose(
				yaw: 0, pitch: 0, roll: 0,
				yawSource: .unavailable, pitchSource: .unavailable, rollSource: .unavailable
			)
		)
		#expect(!missing.yaw.isFinite && missing.yawSource == .unavailable)
		#expect(missing.yaw != 0)
		#expect(missing.pitch == 0.03 && missing.pitchSource == .vision)
		#expect(!missing.roll.isFinite && missing.rollSource == .unavailable)

		let badVision = FacePose.resolved(visionYaw: .nan, visionPitch: nil, visionRoll: nil, estimate: estimate)
		#expect(!badVision.yaw.isFinite && badVision.yawSource == .vision)
		#expect(badVision.pitchSource == .landmarkEstimate)

		let left = CGPoint(x: 0.3, y: 0.7)
		let right = CGPoint(x: 0.7, y: 0.7)
		let nose = [CGPoint(x: 0.5, y: 0.48)]
		let degenerateEyes: [(CGPoint?, CGPoint?)] = [
			(nil, nil), (left, nil), (nil, right), (left, left),
			(CGPoint(x: .nan, y: 0.7), right),
		]
		for (l, r) in degenerateEyes {
			let pose = FacePose.estimate(leftPupil: l, rightPupil: r, nose: nose)
			#expect(pose.yawSource == .unavailable && pose.pitchSource == .unavailable && pose.rollSource == .unavailable)
			#expect(pose.yaw.isNaN && pose.pitch.isNaN && pose.roll.isNaN)
		}
		for missingNose in [nil, []] as [[CGPoint]?] {
			let pose = FacePose.estimate(leftPupil: left, rightPupil: right, nose: missingNose)
			#expect(pose.yaw.isNaN && pose.pitch.isNaN && pose.roll == 0)
			#expect(pose.yawSource == .unavailable && pose.pitchSource == .unavailable && pose.rollSource == .landmarkEstimate)
		}
		let measured = FacePose.estimate(leftPupil: left, rightPupil: right, nose: nose)
		#expect(measured.yawSource == .landmarkEstimate && measured.pitchSource == .landmarkEstimate)
		#expect(abs(measured.yaw) < 0.000001 && abs(measured.pitch) < 0.000001)
	}

	@Test func unchangedSourceSuccessAndSourceTransitionInvalidation() throws {
		let left = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(left, yaw: 0.0) }
		#expect(left.isBaselineReady)
		for _ in 0..<2 { feed(left, yaw: 0.35) }
		#expect(left.isReturningToRest && !left.isComplete)
		#expect(left.guidancePrompt == "Return to your starting position")
		#expect(abs(try #require(left.poseMeasurement(yaw: 0.35, pitch: 0, yawSource: .vision, pitchSource: .vision)).returnTolerance - 0.10) < 0.000001)
		let done = feed(left, yaw: 0.0)
		#expect(left.isComplete && !done.poseSourceInvalidated)

		let right = LivenessChallenge(action: .turnRight)
		for _ in 0..<3 { prepare(right, yaw: 0.0, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate) }
		for _ in 0..<2 { feed(right, yaw: -0.35, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate) }
		#expect(right.isReturningToRest)
		let rightDone = feed(right, yaw: 0.0, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate)
		#expect(right.isComplete && !rightDone.poseSourceInvalidated)

		let nod = LivenessChallenge(action: .nod)
		for _ in 0..<3 { prepare(nod, yaw: 0, pitch: 0.0) }
		for _ in 0..<2 { feed(nod, yaw: 0, pitch: 0.22) }
		#expect(nod.isReturningToRest)
		#expect(abs(try #require(nod.poseMeasurement(yaw: 0, pitch: 0.22, yawSource: .vision, pitchSource: .vision)).returnTolerance - 0.06) < 0.000001)
		feed(nod, yaw: 0, pitch: 0.0)
		#expect(nod.isComplete)

		// Source transition invalidates.
		let challenge = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(challenge, yaw: 0.0) }
		#expect(challenge.isBaselineReady)
		let first = feed(challenge, yaw: 0.35)
		#expect(!first.poseSourceInvalidated && !challenge.isReturningToRest)
		let switched = feed(challenge, yaw: 0.35, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate)
		#expect(switched.poseSourceInvalidated)
		#expect(!challenge.isBaselineReady && !challenge.isReturningToRest && !challenge.isComplete)
		#expect(challenge.poseMeasurement(yaw: 0.35, pitch: 0, yawSource: .vision, pitchSource: .vision) == nil)
		let flapped = feed(challenge, yaw: 0.0)
		#expect(flapped.poseSourceInvalidated && !challenge.isBaselineReady)
		for _ in 0..<2 { feed(challenge, yaw: 0.0) }
		#expect(challenge.isBaselineReady)
		for _ in 0..<2 { feed(challenge, yaw: 0.35) }
		#expect(challenge.isReturningToRest)
		feed(challenge, yaw: 0.0)
		#expect(challenge.isComplete)

		let returning = LivenessChallenge(action: .turnRight)
		for _ in 0..<3 { prepare(returning, yaw: 0.0) }
		for _ in 0..<2 { feed(returning, yaw: -0.35) }
		#expect(returning.isReturningToRest)
		let cut = feed(returning, yaw: -0.35, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate)
		#expect(cut.poseSourceInvalidated && !returning.isReturningToRest && !returning.isComplete)
	}

	@Test func unavailableUnrelatedAxesAndPoseIndependentActions() {
		let challenge = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(challenge, yaw: 0.0) }
		for _ in 0..<2 { feed(challenge, yaw: 0.35) }
		#expect(challenge.isReturningToRest)
		let dropped = feed(challenge, yaw: 0.35, yawSource: .unavailable, pitchSource: .vision)
		#expect(dropped.poseSourceInvalidated)
		#expect(!challenge.isBaselineReady && !challenge.isReturningToRest)

		let steady = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(steady, yaw: 0.0) }
		let pitchGone = feed(steady, yaw: 0.0, pitch: .nan, pitchSource: .unavailable)
		#expect(!pitchGone.poseSourceInvalidated && steady.isBaselineReady)
		for _ in 0..<2 { feed(steady, yaw: 0.35, pitch: .nan, pitchSource: .unavailable) }
		#expect(steady.isReturningToRest)
		feed(steady, yaw: 0.0, pitch: .nan, pitchSource: .unavailable)
		#expect(steady.isComplete)

		let nod = LivenessChallenge(action: .nod)
		for _ in 0..<3 { prepare(nod, yaw: 0, pitch: 0.0) }
		let nodDropped = feed(nod, yaw: 0, pitch: 0.22, pitchSource: .unavailable)
		#expect(nodDropped.poseSourceInvalidated && !nod.isBaselineReady)

		// Unrelated axis flapping never resets.
		let turn = LivenessChallenge(action: .turnLeft)
		prepare(turn, yaw: 0.0, pitch: 0.0, pitchSource: .vision)
		prepare(turn, yaw: 0.0, pitch: 0.05, pitchSource: .landmarkEstimate)
		prepare(turn, yaw: 0.0, pitch: .nan, pitchSource: .unavailable)
		#expect(turn.isBaselineReady)
		let moved = feed(turn, yaw: 0.35, pitch: 0.2, pitchSource: .landmarkEstimate)
		#expect(!moved.poseSourceInvalidated)
		feed(turn, yaw: 0.35, pitch: .nan, pitchSource: .unavailable)
		#expect(turn.isReturningToRest)
		feed(turn, yaw: 0.0)
		#expect(turn.isComplete)

		let nodFlap = LivenessChallenge(action: .nod)
		prepare(nodFlap, yaw: 0.0, pitch: 0.0)
		prepare(nodFlap, yaw: 0.4, pitch: 0.0, yawSource: .landmarkEstimate)
		prepare(nodFlap, yaw: .nan, pitch: 0.0, yawSource: .unavailable)
		#expect(nodFlap.isBaselineReady)
		for _ in 0..<2 { feed(nodFlap, yaw: 0.3, pitch: 0.22, yawSource: .landmarkEstimate) }
		#expect(nodFlap.isReturningToRest)
		feed(nodFlap, yaw: .nan, pitch: 0.0, yawSource: .unavailable)
		#expect(nodFlap.isComplete)

		// Blink and mouth are pose-independent.
		let blink = LivenessChallenge(action: .blink)
		for _ in 0..<3 {
			prepare(blink, yaw: .nan, pitch: .nan, yawSource: .unavailable, pitchSource: .unavailable, eyes: 0.3)
		}
		#expect(blink.isBaselineReady)
		let shut = feed(blink, yaw: 0.5, pitch: -0.4, yawSource: .landmarkEstimate, pitchSource: .vision, eyes: 0.10)
		#expect(!shut.poseSourceInvalidated && blink.isReturningToRest)
		feed(blink, yaw: .nan, pitch: .nan, yawSource: .unavailable, pitchSource: .unavailable, eyes: 0.10)
		#expect(blink.isReturningToRest)
		let opened = feed(blink, yaw: 0.9, pitch: 0.9, yawSource: .landmarkEstimate, eyes: 0.3)
		#expect(blink.isComplete && !opened.poseSourceInvalidated)

		let mouth = LivenessChallenge(action: .openMouth)
		for _ in 0..<3 {
			prepare(mouth, yaw: .nan, pitch: .nan, yawSource: .unavailable, pitchSource: .unavailable, mouth: 0.1)
		}
		#expect(mouth.isBaselineReady)
		feed(mouth, yaw: 0.5, pitch: 0.5, yawSource: .landmarkEstimate, mouth: 0.4)
		feed(mouth, yaw: .nan, pitch: .nan, yawSource: .unavailable, pitchSource: .unavailable, mouth: 0.4)
		#expect(mouth.isReturningToRest)
		let relaxed = feed(mouth, yaw: -0.7, pitch: 0.2, yawSource: .landmarkEstimate, mouth: 0.1)
		#expect(mouth.isComplete && !relaxed.poseSourceInvalidated)

		let missing = LivenessChallenge(action: .blink)
		for _ in 0..<3 { prepare(missing, eyes: 0.3) }
		#expect(missing.isBaselineReady)
		feed(missing, eyes: nil)
		#expect(!missing.isBaselineReady)
	}

	@Test func nonfiniteResetDiagnosticsAndDirectionMapping() throws {
		let turn = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(turn, yaw: 0.0) }
		let bad = feed(turn, yaw: .nan)
		#expect(bad.poseSourceInvalidated && !turn.isBaselineReady)
		feed(turn, yaw: .infinity)
		#expect(!turn.isBaselineReady)
		for _ in 0..<3 { prepare(turn, yaw: .nan) }
		#expect(!turn.isBaselineReady)

		let steady = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(steady, yaw: 0.0, pitch: .nan) }
		#expect(steady.isBaselineReady)

		let legacy = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { legacy.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1) }
		legacy.consume(yaw: 0.35, pitch: 0, eyes: 0.3, mouth: 0.1)
		legacy.consume(yaw: 0.35, pitch: 0, eyes: 0.3, mouth: 0.1)
		#expect(legacy.isReturningToRest)

		// Reset reacquisition.
		let challenge = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(challenge, yaw: 0.0) }
		feed(challenge, yaw: 0.35, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate)
		#expect(!challenge.isBaselineReady)
		challenge.reset()
		#expect(!challenge.isBaselineReady && !challenge.isReturningToRest && !challenge.isComplete)
		#expect(challenge.poseMeasurement(yaw: 0, pitch: 0, yawSource: .vision, pitchSource: .vision) == nil)
		for _ in 0..<3 { prepare(challenge, yaw: -0.1, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate) }
		#expect(challenge.isBaselineReady)
		for _ in 0..<2 { feed(challenge, yaw: 0.25, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate) }
		#expect(challenge.isReturningToRest)
		feed(challenge, yaw: -0.1, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate)
		#expect(challenge.isComplete)
		let previous = challenge.action
		challenge.next()
		#expect(challenge.action != previous && !challenge.isComplete && !challenge.isBaselineReady)

		// Diagnostics respect source.
		let diag = LivenessChallenge(action: .turnLeft)
		#expect(diag.poseMeasurement(yaw: 0.2, pitch: 0, yawSource: .vision, pitchSource: .vision) == nil)
		for _ in 0..<3 { prepare(diag, yaw: 0.2) }
		let same = try #require(diag.poseMeasurement(yaw: 0.55, pitch: 0, yawSource: .vision, pitchSource: .vision))
		#expect(abs(same.offset - 0.35) < 0.000001)
		#expect(diag.poseMeasurement(yaw: 0.55, pitch: 0, yawSource: .landmarkEstimate, pitchSource: .landmarkEstimate) == nil)
		#expect(diag.poseMeasurement(yaw: 0.55, pitch: 0, yawSource: .unavailable, pitchSource: .vision) == nil)
		#expect(!diag.isReturningToRest)
		let blink = LivenessChallenge(action: .blink)
		for _ in 0..<3 { prepare(blink, eyes: 0.3) }
		#expect(blink.poseMeasurement(yaw: 0, pitch: 0, yawSource: .vision, pitchSource: .vision) == nil)

		// Direction mapping.
		let directions: [(LivenessChallenge.Action, Double, Double)] = [
			(.turnLeft, -0.4, 0.4),
			(.turnRight, 0.4, -0.4),
		]
		for (action, badYaw, goodYaw) in directions {
			let dirChallenge = LivenessChallenge(action: action)
			for _ in 0..<3 { prepare(dirChallenge, yaw: 0.0) }
			for _ in 0..<2 { feed(dirChallenge, yaw: badYaw) }
			#expect(!dirChallenge.isReturningToRest && !dirChallenge.isComplete)
			for _ in 0..<2 { feed(dirChallenge, yaw: goodYaw) }
			#expect(dirChallenge.isReturningToRest)
			feed(dirChallenge, yaw: 0.0)
			#expect(dirChallenge.isComplete)
		}
	}
}
