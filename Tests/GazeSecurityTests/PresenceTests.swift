import Foundation
import GazeCamera
import GazeSecurity
import Testing

@Suite("Presence Absence Gate & Retry Schedule")
struct PresenceTests {
	private typealias Gate = PresenceAbsenceGate
	private typealias Observation = PresenceAbsenceGate.Observation
	private typealias Verdict = PresenceAbsenceGate.Verdict

	private func noFace(
		_ id: UInt64,
		captured: Double,
		observed: Double? = nil,
		age: Double = 0.1
	) -> Observation {
		Observation(sample: .noFace, frameID: id, capturedAt: captured, observedAt: observed ?? captured + age)
	}

	private func face(_ id: UInt64, captured: Double, age: Double = 0.1) -> Observation {
		Observation(sample: .facePresent, frameID: id, capturedAt: captured, observedAt: captured + age)
	}

	private func unknown(_ id: UInt64, captured: Double, age: Double = 0.1) -> Observation {
		Observation(sample: .indeterminate, frameID: id, capturedAt: captured, observedAt: captured + age)
	}

	@Test func policyConstantsArePinned() {
		#expect(Gate().requiredAbsence == 4)
		#expect(Gate().maximumAge == 0.5)
		#expect(Gate().maximumGap == 1)
	}

	@Test func sustainedFreshNoFaceAndReturningFaceLifecycle() {
		// Startup-only delay: silence or a single frame never proves absence.
		var gate = Gate()
		#expect(!gate.hasEvidence)
		#expect(gate.provenSpan == nil)
		#expect(gate.update(noFace(1, captured: 0)) == .needMore)
		#expect(gate.hasEvidence)

		// Sustained distinct fresh no-face proves absence at exactly the span.
		gate = Gate()
		var verdicts: [Verdict] = []
		for i in 0..<9 {
			verdicts.append(gate.update(noFace(UInt64(i + 1), captured: Double(i) * 0.5)))
		}
		#expect(verdicts.prefix(8).allSatisfy { $0 == .needMore })
		#expect(verdicts.last == .absent)
		#expect(gate.provenSpan == 4.0)

		// Production-rate polling (every 400ms) also completes on capture span.
		gate = Gate()
		var last: Verdict = .needMore
		for i in 0..<11 {
			last = gate.update(noFace(UInt64(i + 1), captured: Double(i) * 0.4))
		}
		#expect(last == .absent)

		// A returning face cancels, and proof restarts from zero afterwards.
		gate = Gate()
		for i in 0..<5 {
			#expect(gate.update(noFace(UInt64(i + 1), captured: Double(i) * 0.5)) == .needMore)
		}
		#expect(gate.update(face(6, captured: 2.5)) == .present)
		#expect(!gate.hasEvidence)
		for i in 0..<8 {
			#expect(gate.update(noFace(UInt64(7 + i), captured: 3.0 + Double(i) * 0.5)) == .needMore)
		}
		#expect(gate.update(noFace(15, captured: 7.0)) == .absent)

		// A face immediately after proof still cancels.
		gate = Gate()
		for i in 0..<9 {
			_ = gate.update(noFace(UInt64(i + 1), captured: Double(i) * 0.5))
		}
		#expect(gate.update(face(10, captured: 4.5)) == .present)
	}

	@Test func unknownStaleDuplicateOutOfOrderAndGappedFramesResetProof() {
		// Unknown analysis output restarts the window without cancelling the check.
		var gate = Gate()
		for i in 0..<3 {
			_ = gate.update(noFace(UInt64(i + 1), captured: Double(i) * 0.5))
		}
		#expect(gate.update(unknown(4, captured: 1.5)) == .needMore)
		#expect(!gate.hasEvidence)
		for i in 0..<8 {
			#expect(gate.update(noFace(UInt64(5 + i), captured: 2.0 + Double(i) * 0.5)) == .needMore)
		}
		#expect(gate.update(noFace(13, captured: 6.0)) == .absent)

		// Stale captures restart the window.
		gate = Gate()
		_ = gate.update(noFace(1, captured: 0))
		#expect(gate.update(noFace(2, captured: 0.5, observed: 5.0)) == .needMore)
		#expect(!gate.hasEvidence)
		for i in 0..<8 {
			_ = gate.update(noFace(UInt64(3 + i), captured: 5.0 + Double(i) * 0.5))
		}
		#expect(gate.update(noFace(11, captured: 9.0)) == .absent)

		// Repeated samples never extend proof.
		gate = Gate()
		#expect(gate.update(noFace(1, captured: 0)) == .needMore)
		for k in 0..<10 {
			#expect(gate.update(noFace(1, captured: 0, observed: 0.5 + Double(k) * 0.5)) == .needMore)
		}
		#expect(gate.provenSpan == nil)
		for i in 1..<9 {
			_ = gate.update(noFace(UInt64(i + 1), captured: 6.0 + Double(i) * 0.5))
		}
		#expect(gate.update(noFace(10, captured: 10.5)) == .absent)

		// Future timestamps restart the window.
		gate = Gate()
		_ = gate.update(noFace(1, captured: 0))
		#expect(gate.update(noFace(2, captured: 10.0, observed: 9.0)) == .needMore)
		#expect(!gate.hasEvidence)

		// Reordered captures restart the window.
		gate = Gate()
		_ = gate.update(noFace(1, captured: 2.0))
		#expect(gate.update(noFace(2, captured: 1.0, observed: 2.5)) == .needMore)
		#expect(!gate.hasEvidence)

		// A gap beyond the allowance restarts the window instead of bridging it.
		gate = Gate()
		_ = gate.update(noFace(1, captured: 0))
		#expect(gate.update(noFace(2, captured: 5.0)) == .needMore)
		#expect(gate.provenSpan == 0)
		for i in 1..<9 {
			_ = gate.update(noFace(UInt64(2 + i), captured: 5.0 + Double(i) * 0.5))
		}
		#expect(gate.update(noFace(11, captured: 9.5)) == .absent)

		// A short gap within the allowance is tolerated.
		gate = Gate()
		_ = gate.update(noFace(1, captured: 0))
		#expect(gate.update(noFace(2, captured: 0.9)) == .needMore)
	}

	@Test func preLockDecisionRequiresEveryCondition() {
		let allowing = PresenceLockDecision(
			executionPermitsLocking: true,
			permissionsGranted: true,
			walkAwayEnabled: true,
			paused: false,
			cancelled: false,
			generationCurrent: true,
			sessionUnlockedAndActive: true,
			inputIdle: true,
			displayAssertionHeld: false,
			absenceProven: true
		)
		#expect(allowing.allowsLock)

		var decision = allowing
		decision.executionPermitsLocking = false
		#expect(!decision.allowsLock)

		decision = allowing
		decision.permissionsGranted = false
		#expect(!decision.allowsLock)

		decision = allowing
		decision.walkAwayEnabled = false
		#expect(!decision.allowsLock)

		decision = allowing
		decision.paused = true
		#expect(!decision.allowsLock)

		decision = allowing
		decision.cancelled = true
		#expect(!decision.allowsLock)

		decision = allowing
		decision.generationCurrent = false
		#expect(!decision.allowsLock)

		decision = allowing
		decision.sessionUnlockedAndActive = false
		#expect(!decision.allowsLock)

		decision = allowing
		decision.inputIdle = false
		#expect(!decision.allowsLock)

		decision = allowing
		decision.displayAssertionHeld = true
		#expect(!decision.allowsLock)

		decision = allowing
		decision.absenceProven = false
		#expect(!decision.allowsLock)
	}

	@Test func interruptedFramesAndBriefInterPollFace() {
		var gate = Gate()
		_ = gate.update(noFace(1, captured: 0))
		_ = gate.update(unknown(1, captured: 0.1))
		#expect(!gate.hasEvidence)

		_ = gate.update(noFace(3, captured: 0.2))
		_ = gate.update(noFace(2, captured: 0.3))
		#expect(!gate.hasEvidence)

		for badTime in [Double.nan, .infinity, -.infinity] {
			gate = Gate()
			_ = gate.update(noFace(1, captured: 0))
			_ = gate.update(noFace(2, captured: badTime))
			#expect(!gate.hasEvidence)
		}

		for duration in [0.0, -1, .nan, .infinity] {
			gate = Gate(requiredAbsence: duration)
			#expect(gate.update(noFace(1, captured: 0)) == .needMore && !gate.hasEvidence)
		}

		// Brief inter-poll face at 50 ms must cancel immediately.
		gate = Gate()
		_ = gate.update(noFace(1, captured: 0))
		#expect(gate.update(face(2, captured: 0.05)) == .present)
		_ = gate.update(noFace(3, captured: 0.1))
		#expect(gate.provenSpan == 0)
	}

	@Test func retryScheduleCooldownAndInvalidIdleHandling() {
		var schedule = PresenceCheckSchedule()
		let start = ContinuousClock.now
		let tooEarly = schedule.permits(idleSeconds: 19.999, at: start)
		#expect(!tooEarly)
		let armed = schedule.permits(idleSeconds: 20, at: start)
		#expect(armed)
		schedule.finished(at: start)

		for elapsed in [0, 5, 10, 20, 29] {
			let blocked = schedule.permits(idleSeconds: 100, at: start.advanced(by: .seconds(elapsed)))
			#expect(!blocked)
		}
		let retried = schedule.permits(idleSeconds: 100, at: start.advanced(by: .seconds(30)))
		#expect(retried)
		schedule.finished(at: start.advanced(by: .seconds(30)))

		let resetOnInput = schedule.permits(idleSeconds: 0, at: start.advanced(by: .seconds(31)))
		#expect(!resetOnInput)
		let waitAfterInput = schedule.permits(idleSeconds: 19, at: start.advanced(by: .seconds(50)))
		#expect(!waitAfterInput)
		let rearmed = schedule.permits(idleSeconds: 20, at: start.advanced(by: .seconds(51)))
		#expect(rearmed)

		for invalid in [Double.nan, .infinity, -1] {
			let invalidPermitted = schedule.permits(idleSeconds: invalid, at: start)
			#expect(!invalidPermitted)
		}
	}

	@Test func stalePresenceFrameSanitizedToIndeterminateResetsAbsenceInsteadOfBridgingGap() {
		// Regression for frameQueue stale pre-filter bypassing PresenceAbsenceGate reset:
		// Frame 1 (.noFace at 0.0 s) -> Frame 2 (.facePresent captured at 0.1 s, delayed 510 ms)
		// -> Frame 3 (.noFace at 0.65 s, within maximumGap=1.0 s of 0.0 s).
		let t0 = ContinuousClock.now
		var gate = Gate()

		func seconds(since origin: ContinuousClock.Instant, to instant: ContinuousClock.Instant) -> Double {
			let components = origin.duration(to: instant).components
			return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
		}

		func sample(from verdict: PresenceObservation.Verdict) -> PresenceAbsenceGate.Sample {
			switch verdict {
			case .facePresent: .facePresent
			case .noFace: .noFace
			case .indeterminate: .indeterminate
			}
		}

		func feed(_ output: SampleProxy.Output, frameID: UInt64, observedAt: ContinuousClock.Instant) -> Verdict {
			guard case .presence(let verdict, let capturedAt) = output else {
				Issue.record("Expected .presence output")
				return .needMore
			}
			return gate.update(
				Observation(
					sample: sample(from: verdict),
					frameID: frameID,
					capturedAt: seconds(since: t0, to: capturedAt),
					observedAt: seconds(since: t0, to: observedAt)
				)
			)
		}

		let f1 = CameraController.sanitizeForQueue(.presence(verdict: .noFace, capturedAt: t0), now: t0)
		#expect(feed(f1, frameID: 1, observedAt: t0) == .needMore)
		#expect(gate.hasEvidence)

		let f2Captured = t0.advanced(by: .milliseconds(100))
		let f2Done = t0.advanced(by: .milliseconds(610))
		let f2 = CameraController.sanitizeForQueue(.presence(verdict: .facePresent, capturedAt: f2Captured), now: f2Done)
		#expect(feed(f2, frameID: 2, observedAt: f2Done) == .needMore)
		#expect(!gate.hasEvidence)

		// Frame 3 arrives at 0.65 s (0.65 - 0.0 <= 1.0 s), so without the .indeterminate reset
		// Frame 1 -> Frame 3 would bridge across the 510 ms gap and prove absence at 4.0 s.
		let f3Captured = t0.advanced(by: .milliseconds(650))
		let f3 = CameraController.sanitizeForQueue(.presence(verdict: .noFace, capturedAt: f3Captured), now: f3Captured)
		#expect(feed(f3, frameID: 3, observedAt: f3Captured) == .needMore)
		#expect(gate.provenSpan == 0)

		var nextID: UInt64 = 4
		for ms in stride(from: 1_150, through: 4_150, by: 500) {
			let t = t0.advanced(by: .milliseconds(ms))
			let out = CameraController.sanitizeForQueue(.presence(verdict: .noFace, capturedAt: t), now: t)
			#expect(feed(out, frameID: nextID, observedAt: t) == .needMore)
			nextID += 1
		}

		let completion = t0.advanced(by: .milliseconds(4_650))
		let finalOut = CameraController.sanitizeForQueue(.presence(verdict: .noFace, capturedAt: completion), now: completion)
		#expect(feed(finalOut, frameID: nextID, observedAt: completion) == .absent)
	}
}
