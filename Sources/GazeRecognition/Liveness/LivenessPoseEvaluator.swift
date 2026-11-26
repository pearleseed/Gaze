import Foundation
import GazeCamera

extension LivenessChallenge {

	// How far counts. Radians for pose; landmark ratios for eyes and mouth.
	internal static let turnDelta = 0.30      // head clearly turned from where it started
	// A natural nod drops the chin 10 to 20 degrees. 0.18 rad (10.3 degrees) missed the
	// gentle end of that; 0.13 rad (7.4 degrees), held for two frames, still rules out
	// pose noise, which stays within a couple of degrees.
	internal static let nodDelta = 0.13       // chin dropped from where it started
	/// How close to the starting pitch counts as back. Fixed rather than a third of
	/// `nodDelta`, so lowering the entry left the hysteresis gap unchanged.
	internal static let nodReturn = 0.06

	private static let blinkShutFraction: Float = 0.55
	private static let blinkOpenFraction: Float = 0.8
	private static let blinkDropFloor: Float = 0.03
	private static let mouthClosed: Float = 0.16
	private static let mouthOpen: Float = 0.32

	/// Which pose axis the current directional action measures. Passed instead of an
	/// inout baseline so source-invalidation helpers can touch the stored baseline
	/// without overlapping-access conflicts.
	internal enum PoseAxis { case yaw, pitch }

	package func poseMeasurement(yaw: Double, pitch: Double) -> PoseMeasurement? {
		poseMeasurement(yaw: yaw, pitch: pitch, yawSource: .vision, pitchSource: .vision)
	}

	/// Source-aware diagnostics. Returns nil across estimators: an offset from a Vision
	/// baseline to a landmark excursion (or involving an unavailable axis) is not a
	/// movement reading.
	package func poseMeasurement(yaw: Double, pitch: Double, yawSource: FacePose.AxisSource, pitchSource: FacePose.AxisSource) -> PoseMeasurement? {
		guard isBaselineReady, yaw.isFinite, pitch.isFinite else { return nil }
		let baseline: Double?
		let baselineSource: FacePose.AxisSource?
		let valueSource: FacePose.AxisSource
		let value: Double
		let target: Double
		switch action {
		case .turnLeft, .turnRight:
			baseline = baseYaw
			baselineSource = baseYawSource
			value = yaw
			valueSource = yawSource
			target = action == .turnLeft ? Self.turnDelta : -Self.turnDelta
		case .nod:
			baseline = basePitch
			baselineSource = basePitchSource
			value = pitch
			valueSource = pitchSource
			target = Self.nodDelta
		case .blink, .openMouth, .lookLeft, .lookRight:
			return nil
		}
		guard let baseline, let baselineSource,
			baselineSource != .unavailable, valueSource != .unavailable,
			baselineSource == valueSource else { return nil }
		return PoseMeasurement(offset: value - baseline, target: target,
			returnTolerance: action == .nod ? Self.nodReturn : abs(target) / 3)
	}

	/// True when this pose is off its starting point toward the requested side, past the
	/// return window: the head is mid-movement the way it was asked to move. The unlock
	/// loop uses it to tell a face that scores low because it is nodding or turning from
	/// one that scores low because it is someone else. False for actions without a
	/// pose baseline and across estimators.
	package func isMovingAsAsked(_ pose: FacePose) -> Bool {
		guard !isComplete, let measured = poseMeasurement(yaw: pose.yaw, pitch: pose.pitch,
			yawSource: pose.yawSource, pitchSource: pose.pitchSource) else { return false }
		return measured.offset * measured.target > 0 && abs(measured.offset) > measured.returnTolerance
	}

	/// Drops the current action's pose baseline and any partial movement, keeping the
	/// selected action itself: the next samples reacquire from wherever the head is.
	/// Never called for blink/open-mouth, which have no pose baseline to drop.
	internal func invalidatePoseEvidence() {
		switch action {
		case .turnLeft, .turnRight, .lookLeft, .lookRight:
			baseYaw = nil
			baseYawSource = nil
		case .nod:
			basePitch = nil
			basePitchSource = nil
		case .blink, .openMouth:
			return
		}
		baselineSamples = 0
		movementSamples = 0
		observedMovement = false
		baselineGaze = nil
		nilGazeSamples = 0
	}

	internal func preparePoseBaseline(_ value: Double, source: FacePose.AxisSource, axis: PoseAxis) {
		let previous: Double?
		let previousSource: FacePose.AxisSource?
		switch axis {
		case .yaw: previous = baseYaw; previousSource = baseYawSource
		case .pitch: previous = basePitch; previousSource = basePitchSource
		}
		if let previous, let previousSource,
			previousSource == source, abs(value - previous) <= 0.05 {
			baselineSamples = min(3, baselineSamples + 1)
		} else {
			switch axis {
			case .yaw: baseYaw = value; baseYawSource = source
			case .pitch: basePitch = value; basePitchSource = source
			}
			baselineSamples = 1
		}
	}

	internal func prepareBlinkBaseline(eyes: Float?) {
		if let e = eyes, e.isFinite, e >= 0, e > 0 {
			baselineEyeOpenness = baselineSamples == 0 ? e : max(baselineEyeOpenness, e)
			baselineSamples = min(3, baselineSamples + 1)
		} else {
			baselineSamples = 0
		}
		eyesWereOpen = isBaselineReady
	}

	internal func prepareMouthBaseline(mouth: Float?) {
		baselineSamples = mouth.map { $0 < Self.mouthClosed } == true ? min(3, baselineSamples + 1) : 0
		mouthWasClosed = isBaselineReady
	}

	internal func consumeDirectional(_ value: Double, source: FacePose.AxisSource, axis: PoseAxis, threshold: Double, returnTolerance: Double, direction: Double, eyes: Float?, mouth: Float?) -> ConsumeResult {
		switch axis {
		case .yaw:
			guard value.isFinite, source != .unavailable else {
				let hadEvidence = baseYaw != nil || baselineSamples > 0 || movementSamples > 0 || observedMovement
				invalidatePoseEvidence()
				return ConsumeResult(poseSourceInvalidated: hadEvidence)
			}
		case .pitch:
			guard value.isFinite, source != .unavailable else {
				let hadEvidence = basePitch != nil || baselineSamples > 0 || movementSamples > 0 || observedMovement
				invalidatePoseEvidence()
				return ConsumeResult(poseSourceInvalidated: hadEvidence)
			}
		}
		guard eyes.map({ $0.isFinite && $0 >= 0 }) ?? true,
			mouth.map({ $0.isFinite && $0 >= 0 }) ?? true else {
			invalidatePoseEvidence()
			return ConsumeResult()
		}
		return consumePose(value, source: source, axis: axis,
			threshold: threshold, returnTolerance: returnTolerance, direction: direction)
	}

	internal func consumeBlink(eyes: Float?, mouth: Float?) -> ConsumeResult {
		guard eyes.map({ $0.isFinite && $0 >= 0 }) ?? true,
			mouth.map({ $0.isFinite && $0 >= 0 }) ?? true,
			let eyes else { reset(); return ConsumeResult() }
		if !eyesWereOpen {
			if eyes > 0 {
				baselineEyeOpenness = baselineSamples == 0 ? eyes : max(baselineEyeOpenness, eyes)
				baselineSamples += 1
			} else {
				baselineSamples = 0
			}
			eyesWereOpen = baselineSamples >= 3
		} else if !observedMovement, eyes > baselineEyeOpenness {
			baselineEyeOpenness = eyes
		} else if eyes < baselineEyeOpenness * Self.blinkShutFraction,
			baselineEyeOpenness - eyes >= Self.blinkDropFloor {
			observedMovement = true
		} else if observedMovement, eyes > baselineEyeOpenness * Self.blinkOpenFraction {
			isComplete = true
		}
		return ConsumeResult()
	}

	internal func consumeOpenMouth(eyes: Float?, mouth: Float?) -> ConsumeResult {
		guard eyes.map({ $0.isFinite && $0 >= 0 }) ?? true,
			mouth.map({ $0.isFinite && $0 >= 0 }) ?? true,
			let mouth else { reset(); return ConsumeResult() }
		if !mouthWasClosed {
			baselineSamples = mouth < Self.mouthClosed ? baselineSamples + 1 : 0
			mouthWasClosed = baselineSamples >= 3
		} else if !observedMovement {
			movementSamples = mouth > Self.mouthOpen ? movementSamples + 1 : 0
			observedMovement = movementSamples >= 2
		} else if mouth < Self.mouthClosed {
			isComplete = true
		}
		return ConsumeResult()
	}

	private func consumePose(_ value: Double, source: FacePose.AxisSource, axis: PoseAxis, threshold: Double, returnTolerance: Double, direction: Double) -> ConsumeResult {
		let previous: Double?
		let previousSource: FacePose.AxisSource?
		switch axis {
		case .yaw: previous = baseYaw; previousSource = baseYawSource
		case .pitch: previous = basePitch; previousSource = basePitchSource
		}
		if baselineSamples < 3 {
			if let previous, let previousSource,
				previousSource == source, abs(value - previous) <= 0.05 {
				baselineSamples += 1
			} else {
				let hadPartial = previous != nil || baselineSamples > 0
				let sourceChanged = previousSource != nil && previousSource != source
				switch axis {
				case .yaw: baseYaw = value; baseYawSource = source
				case .pitch: basePitch = value; basePitchSource = source
				}
				baselineSamples = 1
				if hadPartial && sourceChanged { return ConsumeResult(poseSourceInvalidated: true) }
			}
			return ConsumeResult()
		}
		guard let current = previous, let currentSource = previousSource else { return ConsumeResult() }
		guard currentSource == source else {
			switch axis {
			case .yaw: baseYaw = value; baseYawSource = source
			case .pitch: basePitch = value; basePitchSource = source
			}
			baselineSamples = 1
			movementSamples = 0
			observedMovement = false
			return ConsumeResult(poseSourceInvalidated: true)
		}
		let delta = value - current
		if !observedMovement {
			movementSamples = delta * direction >= threshold ? movementSamples + 1 : 0
			observedMovement = movementSamples >= 2
		} else if abs(delta) <= returnTolerance {
			isComplete = true
		}
		return ConsumeResult()
	}
}
