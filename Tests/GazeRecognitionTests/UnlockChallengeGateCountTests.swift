import Foundation
import GazeCamera
import GazeRecognition
import GazeSecurity
import Testing

@Suite("Unlock Challenge Gate Configurable Action Counts")
@MainActor
struct UnlockChallengeGateCountTests {
	private func feed(_ challenge: LivenessChallenge, yaw: Double, pitch: Double = 0) {
		challenge.consume(yaw: yaw, pitch: pitch, eyes: 0.3, mouth: 0.1)
	}

	private func completeTurn(
		_ challenge: LivenessChallenge,
		gate: inout UnlockChallengeGate,
		start: ContinuousClock.Instant,
		presentFrame: UInt64,
		excursionYaw: Double
	) {
		for _ in 0..<3 { challenge.prepareBaseline(yaw: 0, pitch: 0, eyes: 0.3, mouth: 0.1) }
		#expect(challenge.isBaselineReady)
		gate.present(at: start, frameID: presentFrame)
		let first = start.advanced(by: .milliseconds(400))
		let a1 = gate.admits(frameID: presentFrame + 1, capturedAt: first, now: first)
		#expect(a1)
		feed(challenge, yaw: excursionYaw)
		#expect(!challenge.isReturningToRest && !challenge.isComplete)
		let second = start.advanced(by: .milliseconds(450))
		let a2 = gate.admits(frameID: presentFrame + 2, capturedAt: second, now: second)
		#expect(a2)
		feed(challenge, yaw: excursionYaw)
		#expect(challenge.isReturningToRest && !challenge.isComplete)
		let returned = start.advanced(by: .milliseconds(600))
		let a3 = gate.admits(frameID: presentFrame + 3, capturedAt: returned, now: returned)
		#expect(a3)
		feed(challenge, yaw: 0.0)
		#expect(challenge.isComplete)
		gate.completeAction()
	}

	@Test func defaultsConfiguredCountsAndInvalidFallbacks() {
		#expect(UnlockChallengeGate.defaultRequiredActions == 2)
		#expect(UnlockChallengeGate().requiredActions == 2)
		#expect(UnlockChallengeGate(requiredActions: 1).requiredActions == 1)
		#expect(UnlockChallengeGate(requiredActions: 2).requiredActions == 2)
		#expect(UnlockChallengeGate(requiredActions: 0).requiredActions == 0)
		#expect(UnlockChallengeGate(requiredActions: 0).isVerified)
		#expect(UnlockChallengeGate.presentationDelay == .milliseconds(350))
		#expect(UnlockChallengeGate.responseTimeout == .seconds(8))

		for value in [3, -1, 99, Int.min, Int.max] {
			let gate = UnlockChallengeGate(requiredActions: value)
			#expect(gate.requiredActions == 2)
			#expect(!gate.isVerified)
		}
	}

	@Test func oneAndTwoActionCompletionAndEvidenceRequirements() {
		let start = ContinuousClock.now

		// One action completion.
		var one = UnlockChallengeGate(requiredActions: 1)
		#expect(!one.isVerified)
		one.present(at: start, frameID: 1)
		#expect(one.isPresented)
		let at = start.advanced(by: .milliseconds(400))
		let oneAdmitted = one.admits(frameID: 2, capturedAt: at, now: at)
		#expect(oneAdmitted)
		one.completeAction()
		#expect(one.completedActions == 1 && one.isVerified)
		#expect(!one.isPresented)
		one.present(at: at, frameID: 3)
		#expect(!one.isPresented && one.isVerified)
		let verifiedAdmit = one.admits(frameID: 4, capturedAt: at, now: at)
		#expect(!verifiedAdmit)
		one.completeAction()
		#expect(one.completedActions == 1 && one.isVerified)

		// Two action completion.
		var two = UnlockChallengeGate(requiredActions: 2)
		two.present(at: start, frameID: 1)
		let first = start.advanced(by: .milliseconds(400))
		let twoFirst = two.admits(frameID: 2, capturedAt: first, now: first)
		#expect(twoFirst)
		two.completeAction()
		#expect(two.completedActions == 1 && !two.isVerified)
		two.completeAction()
		#expect(two.completedActions == 1)
		two.present(at: first, frameID: 3)
		let second = first.advanced(by: .milliseconds(500))
		let twoSecond = two.admits(frameID: 4, capturedAt: second, now: second)
		#expect(twoSecond)
		two.completeAction()
		#expect(two.completedActions == 2 && two.isVerified)

		// Default init requires two.
		var def = UnlockChallengeGate()
		#expect(def.requiredActions == 2)
		def.present(at: start, frameID: 11)
		let defFirst = def.admits(frameID: 12, capturedAt: first, now: first)
		#expect(defFirst)
		def.completeAction()
		#expect(!def.isVerified)
		def.present(at: first, frameID: 13)
		let defSecond = def.admits(frameID: 14, capturedAt: second, now: second)
		#expect(defSecond)
		def.completeAction()
		#expect(def.isVerified)

		// No completion without evidence.
		for count in [1, 2] {
			var unprompted = UnlockChallengeGate(requiredActions: count)
			unprompted.completeAction()
			#expect(!unprompted.isVerified && unprompted.completedActions == 0)
			let unpAdmit = unprompted.admits(frameID: 1, capturedAt: .now, now: .now)
			#expect(!unpAdmit)

			var presented = UnlockChallengeGate(requiredActions: count)
			presented.present(at: .now, frameID: 1)
			presented.completeAction()
			#expect(!presented.isVerified && presented.completedActions == 0)
		}
	}

	@Test func resetPreservesCount() {
		let start = ContinuousClock.now
		for count in [1, 2] {
			var idle = UnlockChallengeGate(requiredActions: count)
			let idleReset = idle.reset()
			#expect(!idleReset)
			#expect(idle.requiredActions == count && !idle.isVerified && idle.completedActions == 0)

			var partial = UnlockChallengeGate(requiredActions: count)
			partial.present(at: start, frameID: 1)
			let at = start.advanced(by: .milliseconds(400))
			let pAdmit = partial.admits(frameID: 2, capturedAt: at, now: at)
			#expect(pAdmit)
			let pReset = partial.reset()
			#expect(pReset)
			#expect(partial.requiredActions == count && partial.completedActions == 0 && !partial.isPresented && !partial.isVerified)
			let pAfter = partial.admits(frameID: 3, capturedAt: at, now: at)
			#expect(!pAfter)

			var full = UnlockChallengeGate(requiredActions: count)
			full.present(at: start, frameID: 11)
			var frame: UInt64 = 12
			var atTime = start.advanced(by: .milliseconds(400))
			for _ in 0..<count {
				let ok = full.admits(frameID: frame, capturedAt: atTime, now: atTime)
				#expect(ok)
				full.completeAction()
				frame += 2
				let presentedAt = atTime
				atTime = atTime.advanced(by: .milliseconds(500))
				if !full.isVerified {
					full.present(at: presentedAt, frameID: frame - 1)
				}
			}
			#expect(full.isVerified)
			let fullReset = full.reset()
			#expect(fullReset)
			#expect(full.requiredActions == count && full.completedActions == 0 && !full.isVerified)
		}

		var interrupted = UnlockChallengeGate(requiredActions: 2)
		interrupted.present(at: start, frameID: 1)
		let at = start.advanced(by: .milliseconds(400))
		let iAdmit = interrupted.admits(frameID: 2, capturedAt: at, now: at)
		#expect(iAdmit)
		interrupted.completeAction()
		let iReset = interrupted.reset()
		#expect(iReset)
		#expect(interrupted.requiredActions == 2 && interrupted.completedActions == 0 && !interrupted.isPresented)
	}

	@Test(arguments: [1, 2])
	func timingReplayAndTurnThroughGate(count: Int) {
		let start = ContinuousClock.now
		var gate = UnlockChallengeGate(requiredActions: count)
		gate.present(at: start, frameID: 100)
		for milliseconds in [-10, 0, 100, 349] {
			let time = start.advanced(by: .milliseconds(milliseconds))
			let early = gate.admits(frameID: 101, capturedAt: time, now: time)
			#expect(!early)
		}
		let response = start.advanced(by: .milliseconds(400))
		let reusePres = gate.admits(frameID: 100, capturedAt: response, now: response)
		#expect(!reusePres)
		let future = gate.admits(frameID: 101, capturedAt: response, now: start)
		#expect(!future)
		let stale = gate.admits(frameID: 101, capturedAt: response, now: response.advanced(by: .seconds(1)))
		#expect(!stale)
		let fresh = gate.admits(frameID: 101, capturedAt: response, now: response)
		#expect(fresh)
		let replay = gate.admits(frameID: 101, capturedAt: response, now: response)
		#expect(!replay)
		let dupTime = gate.admits(frameID: 102, capturedAt: response, now: response)
		#expect(!dupTime)

		var expiring = UnlockChallengeGate(requiredActions: count)
		expiring.present(at: start, frameID: 200)
		#expect(expiring.expired(at: start.advanced(by: .seconds(8))))
		#expect(expiring.expired(at: start.advanced(by: .seconds(-1))))
		let late = start.advanced(by: .seconds(8))
		let lateAdmit = expiring.admits(frameID: 201, capturedAt: late, now: late)
		#expect(!lateAdmit)
		expiring.completeAction()
		#expect(!expiring.isVerified)

		// Turn and return through gate.
		if count == 1 {
			let challenge = LivenessChallenge(action: .turnLeft)
			var oneGate = UnlockChallengeGate(requiredActions: 1)
			completeTurn(challenge, gate: &oneGate, start: start, presentFrame: 300, excursionYaw: 0.35)
			#expect(oneGate.completedActions == 1 && oneGate.isVerified)
		} else {
			let first = LivenessChallenge(action: .turnLeft)
			var twoGate = UnlockChallengeGate(requiredActions: 2)
			completeTurn(first, gate: &twoGate, start: start, presentFrame: 400, excursionYaw: 0.35)
			#expect(twoGate.completedActions == 1 && !twoGate.isVerified)
			let presentedAt = start.advanced(by: .milliseconds(600))
			let second = LivenessChallenge(action: .turnRight)
			completeTurn(second, gate: &twoGate, start: presentedAt, presentFrame: 500, excursionYaw: -0.35)
			#expect(twoGate.completedActions == 2 && twoGate.isVerified)
		}
	}
}
