import Foundation
import GazeCamera
import Observation
import Vision

/// Active challenge–response liveness.
///
/// The camera names a specific, randomly chosen action — turn left, turn right, nod, blink,
/// open your mouth — and passes only when it sees that action actually performed. This is the
/// movement check is supplementary evidence, not proof of a live person. A replay or a
/// manipulated presentation may reproduce motion; evaluate the complete pipeline against
/// those attacks before making any security claim.
///
/// Detection is deliberately *relative*: each directional action measures movement away from
/// where the head started, not an absolute angle. That way it doesn't matter what a person's
/// resting pose is, or whether Vision and the landmark fallback disagree on the zero point —
/// what counts is that the head moved the way it was told to.
///
/// Each directional action additionally pins *which estimator* its baseline came from
/// (Vision or the landmark fallback, tracked per axis). The two disagree on the zero point
/// and the fallback's scale is uncalibrated, so a source change on the action's axis discards
/// that action's baseline and partial movement instead of reading as a turn. The other axis
/// never matters: pitch estimates come and go during a turn without disturbing it, and
/// blink/open-mouth ignore pose entirely.
@MainActor
@Observable
package final class LivenessChallenge {

	package enum Action: CaseIterable, Sendable {
		case turnLeft, turnRight, nod, blink, openMouth, lookLeft, lookRight

		/// True for the eye-only actions, which track pupil shift instead of head pose
		/// and are excluded from the untracked-gaze fallback pick.
		package var isLook: Bool { self == .lookLeft || self == .lookRight }

		package var prompt: String {
			switch self {
			case .turnLeft: return "Turn slightly left"
			case .turnRight: return "Turn slightly right"
			case .nod: return "Nod your head"
			case .blink: return "Blink"
			case .openMouth: return "Open your mouth"
			case .lookLeft, .lookRight: return "Follow the light with your eyes"
			}
		}

		/// Which way the mark should move to show what is being asked.
		///
		/// The panel demonstrates the action rather than only naming it: a face that leans
		/// left is a faster instruction than the words "turn your head left", and the words
		/// underneath are there for the case where it is not obvious. Blink and open-mouth
		/// have no direction, so they pulse in place instead.
		package var hint: (x: CGFloat, y: CGFloat, pulses: Bool) {
			switch self {
			case .turnLeft: return (-1, 0, false)
			case .turnRight: return (1, 0, false)
			case .nod: return (0, 1, false)
			case .blink, .openMouth: return (0, 0, true)
			case .lookLeft: return (-1, 0, true)
			case .lookRight: return (1, 0, true)
			}
		}

		package var symbol: String {
			switch self {
			case .turnLeft: return "arrowshape.left.fill"
			case .turnRight: return "arrowshape.right.fill"
			case .nod: return "arrowshape.down.fill"
			case .blink: return "eye.fill"
			case .openMouth: return "mouth.fill"
			case .lookLeft, .lookRight: return "eye.fill"
			}
		}
	}

	package internal(set) var action: Action = .blink
	package internal(set) var isComplete = false

	/// The head pose at the moment the challenge began, for the directional actions. Movement
	/// is measured from here, so absolute pose and per-camera zero offsets don't matter.
	internal var baseYaw: Double?
	internal var basePitch: Double?
	/// Which estimator each directional baseline came from. A baseline measured with one
	/// source is never compared against movement measured with another.
	internal var baseYawSource: FacePose.AxisSource?
	internal var basePitchSource: FacePose.AxisSource?
	/// Eyes/mouth need a "returned to rest" beat before the action counts, so the user has to
	/// move *into* it rather than already being there.
	internal var eyesWereOpen = false
	/// The person's own resting eye openness, the max of the baseline frames, so
	/// blink thresholds scale to narrow eyes instead of assuming a wide-open rest.
	internal var baselineEyeOpenness: Float = 0
	internal var mouthWasClosed = false
	internal var baselineSamples = 0
	internal var movementSamples = 0
	internal var observedMovement = false
	/// Pupil shift at the moment the look action started, for the eye-only actions.
	/// Movement is measured from here, the same relative rule as the head-pose baselines.
	internal var baselineGaze: Double?
	/// Consecutive look-action frames with no measurable gaze, for the untracked fallback.
	internal var nilGazeSamples = 0

	/// Test hook; the lock screen uses the real clock.
	package var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
	/// Injectable pupil/iris measurement hooks; default to production `PupilLocator`.
	@ObservationIgnored package var eyeWidthProvider: (FaceSample) -> Double? = PupilLocator.eyeWidthPixels
	@ObservationIgnored package var pupilGazeProvider: (FaceSample) -> (x: Double, y: Double?)? = PupilLocator.gaze
	internal var ownLookOrigin: TimeInterval?
	internal var lookCycle: Int?
	internal var lookCycleValid = true
	internal var lookSamples: [(x: Double, y: Double?, target: Double, elapsed: Double)] = []
	/// This frame's vertical gaze, set by the consume entry points; nil when unmeasured.
	internal var frameGazeY: Double?
	internal var baselineGazeY: Double?
	internal var ownLookSeed: UInt64?
	/// Fixes every pass's direction, for tests. Radians, 0 = screen right, counter-clockwise.
	package var lookAngleOverride: Double?
	internal var lookFailures = 0
	/// One compact line per finished look pass ("n=12 r=0.61 range=0.07 cross=0.2
	/// spoilt=false passed=true"), so real-hardware misses can be diagnosed from the log.
	/// Kept for the whole attempt, across passes and movement switches, for the attempt log.
	package internal(set) var lookPassLog: [String] = []
	internal var lookPassCount = 0

	package var isBaselineReady: Bool { baselineSamples >= 3 }
	package var isReturningToRest: Bool { observedMovement && !isComplete }
	package var guidancePrompt: String {
		guard isReturningToRest else { return action.prompt }
		switch action {
		case .turnLeft, .turnRight, .nod: return "Return to your starting position"
		case .blink: return "Open your eyes"
		case .openMouth: return "Relax your mouth"
		case .lookLeft, .lookRight: return "Look back at the middle"
		}
	}
	package var guidanceSymbol: String { isReturningToRest ? "viewfinder" : action.symbol }
	package var guidanceHint: (x: CGFloat, y: CGFloat, pulses: Bool) {
		isReturningToRest ? (0, 0, false) : action.hint
	}

	package struct PoseMeasurement: Sendable {
		package let offset: Double
		package let target: Double
		package let returnTolerance: Double

		package init(offset: Double, target: Double, returnTolerance: Double) {
			self.offset = offset
			self.target = target
			self.returnTolerance = returnTolerance
		}
	}

	/// What one consumed sample did to pose-source tracking. Discardable: callers that
	/// ignore it keep the safe internal behaviour (the baseline is still invalidated);
	/// the unlock loop uses it to drop its wider proof as well.
	package struct ConsumeResult: Sendable, Equatable {
		/// True when this sample discarded a held baseline or partial movement because
		/// the current action's axis changed estimator, went unavailable, or arrived
		/// nonfinite.
		package var poseSourceInvalidated: Bool

		package init(poseSourceInvalidated: Bool = false) {
			self.poseSourceInvalidated = poseSourceInvalidated
		}
	}

	/// The movements people can choose between in Settings. Turn covers both
	/// directions and Follow the light both sides, so the side stays random.
	package enum Movement: String, CaseIterable, Sendable {
		case turn, nod, blink, openMouth, followLight

		package var actions: [Action] {
			switch self {
			case .turn: return [.turnLeft, .turnRight]
			case .nod: return [.nod]
			case .blink: return [.blink]
			case .openMouth: return [.openMouth]
			case .followLight: return [.lookLeft, .lookRight]
			}
		}
	}

	/// Settings key for the movements turned off, as `Movement` raw values.
	package static let disabledMovementsKey = "disabledMovements"

	/// The movements Gaze may ask for, read straight from defaults so this file needs
	/// no Preferences. Never empty: with everything off, all of them are offered.
	package static var offeredActions: [Action] {
		let defaults = UserDefaults.standard
		var off = Set(defaults.stringArray(forKey: disabledMovementsKey) ?? [])
		// The single switch this replaced.
		if defaults.object(forKey: disabledMovementsKey) == nil,
			defaults.object(forKey: "lookMovement") as? Bool == false {
			off.insert(Movement.followLight.rawValue)
		}
		let actions = Movement.allCases.filter { !off.contains($0.rawValue) }.flatMap(\.actions)
		return actions.isEmpty ? Action.allCases : actions
	}

	/// A different offered movement that needs no eye tracking, for when the eyes
	/// cannot be followed.
	internal func fallbackAction() -> Action {
		let offered = Self.offeredActions.filter { $0 != action && !$0.isLook }
		return offered.randomElement()
			?? Action.allCases.filter { $0 != action && !$0.isLook }.randomElement() ?? .blink
	}

	/// False for checks that have no light to follow, like the approval panels:
	/// they only ever ask for movements the camera can see without one.
	private let allowsLook: Bool

	/// The offered movements this check can use, never empty.
	private var choices: [Action] {
		guard !allowsLook else { return Self.offeredActions }
		let still = Self.offeredActions.filter { !$0.isLook }
		return still.isEmpty ? Action.allCases.filter { !$0.isLook } : still
	}

	package init(action: Action? = nil, allowsLook: Bool = true) {
		self.allowsLook = allowsLook
		let start = allowsLook ? Self.offeredActions : Self.offeredActions.filter { !$0.isLook }
		self.action = action ?? start.randomElement() ?? .blink
	}

	/// Pick a fresh random action, different from the current one, and start over.
	package func next() {
		action = choices.filter { $0 != action }.randomElement() ?? choices.first ?? action
		reset()
	}

	package func reset() {
		isComplete = false
		lookPassCount = 0
		baseYaw = nil
		basePitch = nil
		baseYawSource = nil
		basePitchSource = nil
		eyesWereOpen = false
		baselineEyeOpenness = 0
		mouthWasClosed = false
		baselineSamples = 0
		movementSamples = 0
		observedMovement = false
		baselineGaze = nil
		nilGazeSamples = 0
		ownLookOrigin = nil
		ownLookSeed = nil
		baselineGazeY = nil
		lookCycle = nil
		lookCycleValid = true
		lookSamples = []
		lookFailures = 0
	}

	package func prepareBaseline(_ sample: FaceSample) {
		avoidLookWhenFar(sample)
		let eyes2D = action.isLook ? pupilGazeProvider(sample) : nil
		frameGazeY = eyes2D?.y
		prepareBaseline(yaw: sample.pose.yaw, pitch: sample.pose.pitch,
			yawSource: sample.pose.yawSource, pitchSource: sample.pose.pitchSource,
			eyes: Self.eyeOpenness(sample.landmarks), mouth: Self.mouthOpenness(sample.landmarks),
			gaze: action.isLook ? (eyes2D?.x ?? Self.gazeOffset(sample.landmarks)) : nil)
	}

	package func prepareBaseline(yaw: Double, pitch: Double, eyes: Float?, mouth: Float?, gaze: Double? = nil, gazeY: Double? = nil) {
		frameGazeY = gazeY
		prepareBaseline(yaw: yaw, pitch: pitch, yawSource: .vision, pitchSource: .vision,
			eyes: eyes, mouth: mouth, gaze: gaze)
	}

	/// Source-aware baseline. Only the current action's axis can build or break its
	/// baseline: pitch provenance never disturbs a turn, and blink/open-mouth ignore
	/// pose altogether.
	package func prepareBaseline(yaw: Double, pitch: Double, yawSource: FacePose.AxisSource, pitchSource: FacePose.AxisSource, eyes: Float?, mouth: Float?, gaze: Double? = nil) {
		guard eyes.map({ $0.isFinite && $0 >= 0 }) ?? true,
			mouth.map({ $0.isFinite && $0 >= 0 }) ?? true else { reset(); return }
		isComplete = false
		movementSamples = 0
		observedMovement = false
		switch action {
		case .turnLeft, .turnRight:
			guard yaw.isFinite, yawSource != .unavailable else { invalidatePoseEvidence(); return }
			preparePoseBaseline(yaw, source: yawSource, axis: .yaw)
		case .lookLeft, .lookRight:
			guard yaw.isFinite, yawSource != .unavailable else { invalidatePoseEvidence(); return }
			prepareLookBaseline(yaw: yaw, yawSource: yawSource, gaze: gaze)
		case .nod:
			guard pitch.isFinite, pitchSource != .unavailable else { invalidatePoseEvidence(); return }
			preparePoseBaseline(pitch, source: pitchSource, axis: .pitch)
		case .blink:
			prepareBlinkBaseline(eyes: eyes)
		case .openMouth:
			prepareMouthBaseline(mouth: mouth)
		}
	}

	/// Feed each frame. Sets `isComplete` once the current action has been seen.
	@discardableResult
	package func consume(_ sample: FaceSample) -> ConsumeResult {
		avoidLookWhenFar(sample)
		let eyes2D = action.isLook ? pupilGazeProvider(sample) : nil
		frameGazeY = eyes2D?.y
		return consumeFrame(yaw: sample.pose.yaw, pitch: sample.pose.pitch,
			yawSource: sample.pose.yawSource, pitchSource: sample.pose.pitchSource,
			eyes: Self.eyeOpenness(sample.landmarks), mouth: Self.mouthOpenness(sample.landmarks),
			gaze: action.isLook ? (eyes2D?.x ?? Self.gazeOffset(sample.landmarks)) : nil)
	}

	@discardableResult
	package func consume(yaw: Double, pitch: Double, eyes: Float?, mouth: Float?, gaze: Double? = nil, gazeY: Double? = nil) -> ConsumeResult {
		frameGazeY = gazeY
		return consumeFrame(yaw: yaw, pitch: pitch, yawSource: .vision, pitchSource: .vision,
			eyes: eyes, mouth: mouth, gaze: gaze)
	}

	/// Source-aware consumption with an explicit vertical gaze, for tests.
	@discardableResult
	package func consume(yaw: Double, pitch: Double, yawSource: FacePose.AxisSource, pitchSource: FacePose.AxisSource, eyes: Float?, mouth: Float?, gaze: Double? = nil, gazeY: Double?) -> ConsumeResult {
		frameGazeY = gazeY
		return consumeFrame(yaw: yaw, pitch: pitch, yawSource: yawSource, pitchSource: pitchSource,
			eyes: eyes, mouth: mouth, gaze: gaze)
	}

	/// Source-aware consumption. A sample from a different estimator than the baseline —
	/// or with the action's axis unavailable or nonfinite — discards the baseline and
	/// partial movement and reports `poseSourceInvalidated`, so the unlock loop can drop
	/// its wider proof instead of completing across estimators. The sample itself starts
	/// the fresh baseline where possible. Unrelated axes — and, for blink/open-mouth,
	/// all pose input — never invalidate.
	@discardableResult
	package func consume(yaw: Double, pitch: Double, yawSource: FacePose.AxisSource, pitchSource: FacePose.AxisSource, eyes: Float?, mouth: Float?, gaze: Double? = nil) -> ConsumeResult {
		frameGazeY = nil
		return consumeFrame(yaw: yaw, pitch: pitch, yawSource: yawSource, pitchSource: pitchSource,
			eyes: eyes, mouth: mouth, gaze: gaze)
	}

	private func consumeFrame(yaw: Double, pitch: Double, yawSource: FacePose.AxisSource, pitchSource: FacePose.AxisSource, eyes: Float?, mouth: Float?, gaze: Double?) -> ConsumeResult {
		guard !isComplete else { return ConsumeResult() }
		switch action {
		// In the mirrored camera preview, leftward turns increase Vision yaw.
		// Verified against the September 15 recording; see docs/internal/CHALLENGE-INVESTIGATION.md.
		case .turnLeft:
			return consumeDirectional(yaw, source: yawSource, axis: .yaw,
				threshold: Self.turnDelta, returnTolerance: Self.turnDelta / 3, direction: 1, eyes: eyes, mouth: mouth)
		case .turnRight:
			return consumeDirectional(yaw, source: yawSource, axis: .yaw,
				threshold: Self.turnDelta, returnTolerance: Self.turnDelta / 3, direction: -1, eyes: eyes, mouth: mouth)
		// Same polarity as the turns: looking toward the person's own left shifts
		// the pupils toward +x in landmark space, matching +yaw.
		case .lookLeft:
			return consumeLook(yaw: yaw, yawSource: yawSource, direction: 1,
				eyes: eyes, mouth: mouth, gaze: gaze)
		case .lookRight:
			return consumeLook(yaw: yaw, yawSource: yawSource, direction: -1,
				eyes: eyes, mouth: mouth, gaze: gaze)
		case .nod:
			return consumeDirectional(pitch, source: pitchSource, axis: .pitch,
				threshold: Self.nodDelta, returnTolerance: Self.nodReturn, direction: 1, eyes: eyes, mouth: mouth)
		case .blink:
			return consumeBlink(eyes: eyes, mouth: mouth)
		case .openMouth:
			return consumeOpenMouth(eyes: eyes, mouth: mouth)
		}
	}
}
