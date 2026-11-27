import Foundation
import GazeCamera

extension LivenessChallenge {

	private static let headStillLimit = 8 * Double.pi / 180  // head may not wander during a look
	private static let nilGazeLimit = 15     // unmeasurable frames before offering a non-look action

	// Follow the light. The light rests at the centre, glides to the prompted edge,
	// holds, and glides back, over and over; each pass is scored on its own. A laptop
	// screen is small enough to see the edge without moving your eyes, so one glance
	// proves little. Eyes that track a moving light, in time with it, for a whole
	// pass are hard to fake and forgiving of a few noisy frames.
	package static let lookPeriod = 1.3
	private static let lookMinSamples = 7
	private static let lookMinCorrelation = 0.45
	private static let lookMinRange = 0.03
	private static let lookFailureLimit = 3
	/// Total passes before giving up, so short-sample passes that never count as
	/// failures still can't loop forever.
	private static let lookPassLimit = 6

	/// When the light started its path, set by the lock-screen overlay so the light
	/// and the scoring share one clock. Nil elsewhere (Test Recognition, tests): the
	/// challenge then starts its own clock at the first steady frame.
	package static var lookOrigin: TimeInterval?
	/// True while the lock-screen light is up and waiting for the challenge to start it.
	package static var lookOverlayWaiting = false
	/// How long the light waits at the centre after the prompt appears, so it never
	/// starts moving before the person has read what to do.
	package static let lookLeadIn = 0.8
	/// Uptime before which a waiting light may not start, set by the overlay with the
	/// prompt. Nil elsewhere, where there is no light to lead in.
	package static var lookLeadInUntil: TimeInterval?

	/// Where the light is, 0 at the centre to 1 at the edge, `elapsed` seconds into
	/// the repeating path: rest 0.1 s, glide out 0.45 s, hold 0.2 s, glide back
	/// 0.45 s, rest 0.1 s. A 0.85 s pass was tried and failed every time on the lock
	/// screen: frames arrive about ten a second there, too few to score a pass that short.
	package static func lookTargetPosition(elapsed: Double) -> Double {
		guard elapsed.isFinite, elapsed >= 0 else { return 0 }
		let t = elapsed.truncatingRemainder(dividingBy: lookPeriod)
		func ease(_ u: Double) -> Double { let u = min(max(u, 0), 1); return u * u * (3 - 2 * u) }
		switch t {
		case ..<0.1: return 0
		case ..<0.55: return ease((t - 0.1) / 0.45)
		case ..<0.75: return 1
		case ..<1.2: return 1 - ease((t - 0.75) / 0.45)
		default: return 0
		}
	}

	/// Seeds the light's direction for each pass, set by the overlay with `lookOrigin` so
	/// the light and the scoring agree. Every pass starts from the centre and heads off in
	/// a fresh random direction.
	package static var lookSeed: UInt64?

	/// The direction of pass `cycle`, in radians: 0 is screen right, counter-clockwise.
	package static func lookAngle(cycle: Int, seed: UInt64) -> Double {
		var z = seed &+ UInt64(truncatingIfNeeded: cycle) &* 0x9E37_79B9_7F4A_7C15
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		z ^= z >> 31
		// Left or right, tilted at most 20 degrees. With the lid opened wide the camera
		// looks down at the face, the upper lids cover the irises, and up-and-down eye
		// movement all but disappears; side to side stays readable at any angle.
		let u = Double(z >> 11) / Double(1 << 53)
		let side = u < 0.5 ? 0.0 : Double.pi
		let tilt = (u.truncatingRemainder(dividingBy: 0.5) * 2 - 1) * (20 * Double.pi / 180)
		return side + tilt
	}

	/// Eyes move less up and down than side to side for the same distance on screen,
	/// and the light travels less far vertically. The expected vertical pupil shift per
	/// unit of horizontal one; tune from Check eyes.
	package static let lookVerticalGain = 0.5
	private static let lookMaxCrossTalk = 1.0  // The light is side to side now; up-down noise shouldn't fail a pass

	/// Eyes narrower than this, in camera pixels, are too far away for the iris model to
	/// follow reliably (measured on Owen's MacBook Air: fine near, failing a little further).
	package static let lookMinEyeWidth: Double = 32

	/// Swaps Follow the light for another movement when the face is too far for it.
	/// Checked before the prompt shows, so a far-away person never sees it at all.
	internal func avoidLookWhenFar(_ sample: FaceSample) {
		guard action.isLook, let eyeWidth = eyeWidthProvider(sample),
			eyeWidth < Self.lookMinEyeWidth else { return }
		lookPassLog.append("too far for Follow the light (eyes \(Int(eyeWidth)) px); switched movement")
		action = fallbackAction()
		reset()
	}

	/// Baseline anchor for the eye-only actions: the head-pose steadiness rule pins yaw,
	/// and the first steady frame's gaze becomes the pupil anchor. Frames with no
	/// measurable gaze neither build nor break the baseline here; the consume path
	/// switches to a non-look action after enough of them.
	internal func prepareLookBaseline(yaw: Double, yawSource: FacePose.AxisSource, gaze: Double?) {
		guard let gaze, gaze.isFinite else { return }
		if let previous = baseYaw, let previousSource = baseYawSource,
			previousSource == yawSource, abs(yaw - previous) <= 0.05 {
			baselineSamples = min(3, baselineSamples + 1)
		} else {
			baseYaw = yaw
			baseYawSource = yawSource
			baselineGaze = gaze
			baselineGazeY = frameGazeY
			baselineSamples = 1
		}
	}

	/// Eye-only detection: the pupils must shift toward the prompted side while the head
	/// stays within 8 degrees of its baseline yaw. A head turn never counts, and any
	/// frame where the head wandered resets the observed progress without failing.
	/// Frames with no measurable gaze count toward the untracked fallback instead.
	internal func consumeLook(yaw: Double, yawSource: FacePose.AxisSource, direction: Double, eyes: Float?, mouth: Float?, gaze: Double?) -> ConsumeResult {
		guard yaw.isFinite, yawSource != .unavailable else {
			let hadEvidence = baseYaw != nil || baselineSamples > 0 || movementSamples > 0 || observedMovement
			invalidatePoseEvidence()
			return ConsumeResult(poseSourceInvalidated: hadEvidence)
		}
		guard eyes.map({ $0.isFinite && $0 >= 0 }) ?? true,
			mouth.map({ $0.isFinite && $0 >= 0 }) ?? true else {
			invalidatePoseEvidence()
			return ConsumeResult()
		}
		guard let gaze, gaze.isFinite else {
			nilGazeSamples += 1
			guard nilGazeSamples >= Self.nilGazeLimit else { return ConsumeResult() }
			lookPassLog.append("eyes unreadable for \(Self.nilGazeLimit) frames; switched movement")
			action = fallbackAction()
			reset()
			return ConsumeResult()
		}
		nilGazeSamples = 0
		if baselineSamples < 3 {
			if let previous = baseYaw, let previousSource = baseYawSource,
				previousSource == yawSource, abs(yaw - previous) <= 0.05 {
				baselineSamples += 1
			} else {
				let hadPartial = baseYaw != nil || baselineSamples > 0
				let sourceChanged = baseYawSource != nil && baseYawSource != yawSource
				baseYaw = yaw
				baseYawSource = yawSource
				baselineGaze = gaze
				baselineGazeY = frameGazeY
				baselineSamples = 1
				if hadPartial && sourceChanged { return ConsumeResult(poseSourceInvalidated: true) }
			}
			return ConsumeResult()
		}
		guard let anchor = baselineGaze, let base = baseYaw, let baseSource = baseYawSource,
			baseSource == yawSource else {
			baseYaw = yaw
			baseYawSource = yawSource
			baselineGaze = gaze
			baselineGazeY = frameGazeY
			baselineSamples = 1
			movementSamples = 0
			observedMovement = false
			return ConsumeResult(poseSourceInvalidated: true)
		}
		let now = clock()
		if Self.lookOrigin == nil, Self.lookOverlayWaiting {
			// The light holds at the centre through the lead-in; nothing is scored yet.
			if let leadInUntil = Self.lookLeadInUntil, now < leadInUntil { return ConsumeResult() }
			Self.lookOrigin = now
			Self.lookOverlayWaiting = false
		}
		let origin = Self.lookOrigin ?? {
			if ownLookOrigin == nil { ownLookOrigin = now }
			return ownLookOrigin!
		}()
		let elapsed = max(0, now - origin)
		let cycle = Int(elapsed / Self.lookPeriod)
		if let current = lookCycle, cycle != current {
			// A pass just finished: score it, log it, then start collecting the next.
			let spoilt = !lookCycleValid
			let score = scoreLookPass(angle: angle(forCycle: current))
			let passed = !spoilt && score.passed
			lookPassCount += 1
			lookPassLog.append("n=\(score.samples) r=\(String(format: "%.2f", score.correlation)) range=\(String(format: "%.2f", score.range)) cross=\(String(format: "%.2f", score.cross)) spoilt=\(spoilt) passed=\(passed)")
			if passed {
				observedMovement = true
				isComplete = true
				return ConsumeResult()
			}
			// A pass with too few samples is a camera/frame shortfall, not the
			// person failing: start the next pass without counting a failure.
			let shortfall = !spoilt && score.samples < Self.lookMinSamples
			// Every other non-passing pass counts, including ones spoilt by a
			// head turn, so it never loops forever: after a few, a different
			// movement is asked for.
			if !shortfall { lookFailures += 1 }
			if lookFailures >= Self.lookFailureLimit || lookPassCount >= Self.lookPassLimit {
				action = fallbackAction()
				reset()
				return ConsumeResult()
			}
			lookSamples = []
			lookCycleValid = true
		}
		lookCycle = cycle
		// Turning the head to follow spoils this pass; the next one starts clean.
		guard abs(yaw - base) <= Self.headStillLimit else {
			lookCycleValid = false
			lookSamples = []
			return ConsumeResult()
		}
		if lookCycleValid {
			let dy = frameGazeY.flatMap { y in baselineGazeY.map { y - $0 } }
			lookSamples.append((gaze - anchor, dy, Self.lookTargetPosition(elapsed: elapsed), elapsed))
		}
		return ConsumeResult()
	}

	private func angle(forCycle cycle: Int) -> Double {
		if let lookAngleOverride { return lookAngleOverride }
		let seed = Self.lookSeed ?? {
			if ownLookSeed == nil { ownLookSeed = UInt64.random(in: .min ... .max) }
			return ownLookSeed!
		}()
		return Self.lookAngle(cycle: cycle, seed: seed)
	}

	/// One finished look pass's numbers and whether it passed. Same decision as
	/// before: fitted only when the samples allow, passing only on enough samples
	/// with a tight positive visible fit and little off-axis movement.
	private struct LookPassScore {
		var passed: Bool
		var samples: Int
		var correlation: Double
		var range: Double
		/// Off-axis movement relative to on-axis (|side slope| / slope).
		var cross: Double
	}

	/// Whether the eyes followed the light in the pass just collected.
	///
	/// The pupil movement is projected onto the light's direction and fitted against
	/// the light's distance from the centre. A pass needs the fit to be tight
	/// (correlation), the slope positive and visible (the eyes went the light's way,
	/// far enough), and little of the movement off to the side of that direction.
	private func scoreLookPass(angle: Double) -> LookPassScore {
		// Screen right is image -x for the pupils; up is +y.
		let ex = -cos(angle), ey = sin(angle) * Self.lookVerticalGain
		let norm = ex * ex + ey * ey
		guard norm > 0 else { return LookPassScore(passed: false, samples: 0, correlation: 0, range: 0, cross: 0) }
		let needsVertical = abs(sin(angle)) > 0.25
		var along: [Double] = [], across: [Double] = [], elapsed: [Double] = []
		for sample in lookSamples {
			guard let y = sample.y ?? (needsVertical ? nil : 0) else { continue }
			along.append((sample.x * ex + y * ey) / norm)
			across.append((-sample.x * ey + y * ex) / norm)
			elapsed.append(sample.elapsed)
		}
		// From further away each frame's pupil reading jitters by a few pixels, but the
		// light moves smoothly over half a second. A short centred average (5 frames, about
		// a fifth of a second) cancels the jitter and keeps the movement. A still or wrong
		// face gains nothing: its readings still don't follow the light.
		along = Self.smoothed(along, window: 5)
		across = Self.smoothed(across, window: 5)
		// Eyes trail a moving light by about a tenth to a quarter of a second, and more
		// so from further away. Score against the light as it was a moment earlier, at
		// whichever small lag fits best.
		let targets = [0.0, 0.08, 0.16, 0.24].map { lag in
			elapsed.map { Self.lookTargetPosition(elapsed: max(0, $0 - lag)) }
		}.max { a, b in
			(Self.fit(along, a)?.correlation ?? -1) < (Self.fit(along, b)?.correlation ?? -1)
		} ?? []
		var correlation = 0.0, range = 0.0, cross = 0.0
		var passed = false
		if let fit = Self.fit(along, targets), let side = Self.fit(across, targets) {
			let sorted = along.sorted()
			range = sorted[Int(Double(sorted.count - 1) * 0.9)] - sorted[Int(Double(sorted.count - 1) * 0.1)]
			correlation = fit.correlation
			cross = fit.slope != 0 ? abs(side.slope / fit.slope) : 0
			passed = along.count >= Self.lookMinSamples
				&& fit.correlation >= Self.lookMinCorrelation && fit.slope > 0 && range >= Self.lookMinRange
				&& abs(side.slope) <= Self.lookMaxCrossTalk * fit.slope
		}
		return LookPassScore(passed: passed, samples: along.count,
			correlation: correlation, range: range, cross: cross)
	}

	/// Centred moving average; the ends average over what is available.
	package static func smoothed(_ values: [Double], window: Int) -> [Double] {
		guard values.count > 2, window > 1 else { return values }
		let half = window / 2
		return values.indices.map { i in
			let lo = max(0, i - half), hi = min(values.count - 1, i + half)
			return values[lo...hi].reduce(0, +) / Double(hi - lo + 1)
		}
	}

	/// Least-squares slope of `values` against `targets`, and their correlation.
	private static func fit(_ values: [Double], _ targets: [Double]) -> (slope: Double, correlation: Double)? {
		let n = Double(values.count)
		guard n > 1 else { return nil }
		let mv = values.reduce(0, +) / n, mt = targets.reduce(0, +) / n
		var cov = 0.0, vv = 0.0, vt = 0.0
		for (v, t) in zip(values, targets) {
			cov += (v - mv) * (t - mt); vv += (v - mv) * (v - mv); vt += (t - mt) * (t - mt)
		}
		guard vt > 0 else { return nil }
		return (cov / vt, vv > 0 ? cov / (vv.squareRoot() * vt.squareRoot()) : 0)
	}
}
