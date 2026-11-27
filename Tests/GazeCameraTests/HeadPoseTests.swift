import Foundation
import GazeCamera
import GazeRecognition
import Testing

@Suite("Head Pose & Mirrored Ring Direction")
@MainActor
struct HeadPoseTests {
	@Test func recordedLeftRightExcursionsReturnAndReset() {
		let cases: [(LivenessChallenge.Action, [Double], [Double], Double)] = [
			(.turnLeft, [-0.08, -0.11, -0.10], [0.26, 0.41], -0.02),
			(.turnRight, [-0.02, -0.02, -0.02], [-0.54, -0.65], -0.11),
		]
		for (action, baseline, excursion, returned) in cases {
			let challenge = LivenessChallenge(action: action)
			for yaw in baseline {
				challenge.prepareBaseline(yaw: yaw, pitch: 0, eyes: 0.3, mouth: 0.1)
			}
			#expect(challenge.isBaselineReady)
			challenge.consume(yaw: excursion[0], pitch: 0, eyes: 0.3, mouth: 0.1)
			#expect(!challenge.isReturningToRest && !challenge.isComplete)
			challenge.consume(yaw: excursion[1], pitch: 0, eyes: 0.3, mouth: 0.1)
			#expect(
				challenge.isReturningToRest && !challenge.isComplete,
				"The recorded movement must agree with the mirrored demonstration"
			)
			challenge.consume(yaw: returned, pitch: 0, eyes: 0.3, mouth: 0.1)
			#expect(challenge.isComplete)
			challenge.reset()
			#expect(!challenge.isComplete && !challenge.isBaselineReady)
		}
	}

	@Test func ringAngleMatchesMirroredDirections() {
		#expect(sin(FacePose(yaw: 0.4, pitch: 0, roll: 0).ringAngle) < -0.99)
		#expect(sin(FacePose(yaw: -0.4, pitch: 0, roll: 0).ringAngle) > 0.99)
		#expect(cos(FacePose(yaw: 0, pitch: 0.4, roll: 0).ringAngle) < -0.99)
	}
}
