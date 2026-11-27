import Foundation
import GazeCamera
import GazeRecognition
import GazeSecurity
import Testing

@Suite("Challenge & Pose Integration")
@MainActor
struct ChallengePoseIntegrationTests {
	private func prepare(_ challenge: LivenessChallenge, yaw: Double, pitch: Double = 0) {
		let pose = FacePose(yaw: yaw, pitch: pitch, roll: 0)
		challenge.prepareBaseline(yaw: pose.yaw, pitch: pose.pitch, eyes: 0.3, mouth: 0.1)
	}

	private func feed(_ challenge: LivenessChallenge, yaw: Double, pitch: Double = 0) {
		let pose = FacePose(yaw: yaw, pitch: pitch, roll: 0)
		challenge.consume(yaw: pose.yaw, pitch: pose.pitch, eyes: 0.3, mouth: 0.1)
	}

	@Test func gateConstantsArePinned() {
		#expect(UnlockChallengeGate.defaultRequiredActions == 2)
		#expect(UnlockChallengeGate.presentationDelay == .milliseconds(350))
		#expect(UnlockChallengeGate.responseTimeout == .seconds(8))
	}

	@Test func nonfrontalReturnToStart() throws {
		let cases: [(LivenessChallenge.Action, Double, Double)] = [
			(.turnLeft, 0.20, 0.55),
			(.turnRight, -0.20, -0.55),
		]
		for (action, base, excursion) in cases {
			let challenge = LivenessChallenge(action: action)
			for _ in 0..<3 { prepare(challenge, yaw: base) }
			#expect(challenge.isBaselineReady)
			let measured = try #require(challenge.poseMeasurement(yaw: excursion, pitch: 0))
			#expect(abs(measured.offset - (excursion - base)) < 0.000001)
			#expect(abs(measured.returnTolerance - 0.10) < 0.000001)
			for _ in 0..<2 { feed(challenge, yaw: excursion) }
			#expect(challenge.isReturningToRest && !challenge.isComplete)
			#expect(challenge.guidancePrompt == "Return to your starting position")
			feed(challenge, yaw: 0.0)
			#expect(!challenge.isComplete && challenge.isReturningToRest)
			feed(challenge, yaw: base)
			#expect(challenge.isComplete)
		}
	}

	@Test func retryReacquisition() throws {
		let challenge = LivenessChallenge(action: .turnLeft)
		for _ in 0..<2 { prepare(challenge, yaw: 0.20) }
		#expect(!challenge.isBaselineReady)
		for _ in 0..<3 { prepare(challenge, yaw: 0.0) }
		#expect(challenge.isBaselineReady)
		#expect(try #require(challenge.poseMeasurement(yaw: 0.0, pitch: 0)).offset == 0)
		for _ in 0..<2 { feed(challenge, yaw: 0.35) }
		#expect(challenge.isReturningToRest)
		challenge.reset()
		#expect(!challenge.isBaselineReady && !challenge.isReturningToRest && !challenge.isComplete)
		for _ in 0..<3 { prepare(challenge, yaw: -0.15) }
		#expect(challenge.isBaselineReady)
		#expect(try #require(challenge.poseMeasurement(yaw: -0.15, pitch: 0)).offset == 0)
	}

	@Test func poseSourceSwitch() {
		let biased = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(biased, yaw: 0.10) }
		for _ in 0..<2 { feed(biased, yaw: 0.45) }
		#expect(biased.isReturningToRest)
		feed(biased, yaw: 0.25)
		#expect(!biased.isComplete && biased.isReturningToRest)
		feed(biased, yaw: 0.10)
		#expect(biased.isComplete)

		let nod = LivenessChallenge(action: .nod)
		for _ in 0..<3 { prepare(nod, yaw: 0, pitch: 0.25) }
		#expect(nod.isBaselineReady)
		for _ in 0..<2 { feed(nod, yaw: 0, pitch: 0.20) }
		#expect(!nod.isReturningToRest)
	}

	@Test func promptAdmissionTiming() {
		let start = ContinuousClock.now
		let challenge = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(challenge, yaw: 0.0) }
		var gate = UnlockChallengeGate()
		gate.present(at: start, frameID: 7)
		let early = start.advanced(by: .milliseconds(100))
		let earlyAdmitted = gate.admits(frameID: 8, capturedAt: early, now: early)
		#expect(!earlyAdmitted)

		for (frameID, milliseconds) in [(UInt64(9), 400), (UInt64(10), 450)] {
			let at = start.advanced(by: .milliseconds(milliseconds))
			let ok = gate.admits(frameID: frameID, capturedAt: at, now: at)
			#expect(ok)
			feed(challenge, yaw: 0.35)
		}
		#expect(challenge.isReturningToRest && !challenge.isComplete)

		let returned = start.advanced(by: .milliseconds(800))
		let retOk = gate.admits(frameID: 11, capturedAt: returned, now: returned)
		#expect(retOk)
		feed(challenge, yaw: 0.0)
		#expect(challenge.isComplete)
		gate.completeAction()
		#expect(gate.completedActions == 1 && !gate.isVerified)

		let hurried = LivenessChallenge(action: .turnLeft)
		for _ in 0..<3 { prepare(hurried, yaw: 0.0) }
		var hurriedGate = UnlockChallengeGate()
		hurriedGate.present(at: start, frameID: 20)
		for (frameID, milliseconds) in [(UInt64(21), 100), (UInt64(22), 150), (UInt64(23), 200)] {
			let at = start.advanced(by: .milliseconds(milliseconds))
			let ok = hurriedGate.admits(frameID: frameID, capturedAt: at, now: at)
			#expect(!ok)
		}
		#expect(!hurried.isReturningToRest && !hurried.isComplete)
	}
}
