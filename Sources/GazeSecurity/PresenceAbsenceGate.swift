import Foundation

/// Sustained-absence proof for walk-away lock.
///
/// Pure policy: no camera, no preferences, no clock of its own. Time is plain
/// `Double` seconds on any monotonic clock the caller already uses — the
/// watcher passes elapsed time derived from `ContinuousClock`, the regression
/// tests pass a synthetic clock. That is what makes the production rule
/// testable without opening the camera.
///
/// Only distinct, fresh, explicitly analyzed no-face evidence extends the
/// proof. Everything else either cancels it or restarts it:
///
/// - `facePresent` (one face, or several — any detected face means someone is
///   there) cancels outright, even on a repeated frame.
/// - `indeterminate` (`detectionFailed` / `analysisFailed`) restarts the
///   window: an unknown interval must never sit inside proven absence.
/// - Stale (older than `maximumAge`), future (`capturedAt` after `observedAt`)
///   and out-of-order captures restart the window.
	/// - Fresh repeats carry no new evidence
///   and change nothing. The watcher polls, so most polls re-read the frame it
///   already fed in; those must neither extend nor destroy the proof.
///
/// Why this does not reuse `CameraEvidenceContinuity`: that type tracks
/// *recognition* continuity, and no-face frames deliberately invalidate it.
/// `CameraController` records `usable = (absence == nil && qualityUsable)` per
/// frame, so every no-face frame bumps the revision and clears `usable`, and
/// `permits()` is false after any no-face frame by design. Absence needs its
/// own accumulator with the opposite polarity.
package struct PresenceAbsenceGate: Equatable, Sendable {

	/// What one analyzed frame said.
	package enum Sample: Equatable, Sendable {
		/// Exactly one analyzed frame with nobody in it.
		case noFace
		/// A face was detected — one or several. Someone is there.
		case facePresent
		/// The frame was analyzed but said nothing usable: the detector could
		/// not run, or a found face could not be measured.
		case indeterminate
	}

	/// One poll of the camera, translated into clock-agnostic terms.
	package struct Observation: Equatable, Sendable {
		package var sample: Sample
		/// Sequence number of the analyzed frame, including rejected analyses.
		package var frameID: UInt64
		/// When the frame was captured, in caller-clock seconds.
		package var capturedAt: Double
		/// When the poller read it, in the same seconds.
		package var observedAt: Double

		package init(sample: Sample, frameID: UInt64, capturedAt: Double, observedAt: Double) {
			self.sample = sample
			self.frameID = frameID
			self.capturedAt = capturedAt
			self.observedAt = observedAt
		}
	}

	package enum Verdict: Equatable, Sendable {
		case needMore
		/// Terminal for this confirmation: someone is there.
		case present
		/// Terminal for this confirmation: sustained absence is proven.
		case absent
	}

	/// How much continuous no-face proof unlocks the lock. Matches the
	/// watcher's confirmation window.
	package let requiredAbsence: TimeInterval
	/// How old a capture may be when polled and still count. Matches
	/// `CameraFrameLease.maximumAge`: the lease already drops older frames
	/// before they reach the poller, so this is defense in depth for a
	/// stalled pipeline.
	package let maximumAge: TimeInterval
	/// Maximum allowed gap between accepted captures.
	package let maximumGap: TimeInterval

	private var lastFrameID: UInt64?
	private var windowStart: Double?
	private var lastAcceptedAt: Double?

	/// Whether any unbroken no-face evidence is currently held.
	package var hasEvidence: Bool { windowStart != nil }

	/// The span currently proven, if any, measured in capture times — never
	/// in wall/poll delay, so startup latency cannot count toward it.
	package var provenSpan: TimeInterval? {
		guard let start = windowStart, let last = lastAcceptedAt else { return nil }
		return last - start
	}

	package init(requiredAbsence: TimeInterval = 4, maximumAge: TimeInterval = 0.5, maximumGap: TimeInterval = 1) {
		self.requiredAbsence = requiredAbsence
		self.maximumAge = maximumAge
		self.maximumGap = maximumGap
	}

	package mutating func reset() {
		windowStart = nil
		lastAcceptedAt = nil
	}

	package mutating func update(_ observation: Observation) -> Verdict {
		// Any detected face cancels outright, before the duplicate check: a
		// repeated sighting is still a sighting.
		if observation.sample == .facePresent {
			lastFrameID = max(lastFrameID ?? 0, observation.frameID)
			reset()
			return .present
		}
		// Validate before the duplicate check: a repeated frame can become stale.
		let age = observation.observedAt - observation.capturedAt
		guard requiredAbsence.isFinite, requiredAbsence > 0,
			maximumAge.isFinite, maximumAge >= 0, maximumGap.isFinite, maximumGap > 0,
			observation.capturedAt.isFinite, observation.observedAt.isFinite,
			age >= 0, age <= maximumAge, observation.sample == .noFace else {
			lastFrameID = max(lastFrameID ?? 0, observation.frameID)
			reset()
			return .needMore
		}
		if let last = lastFrameID, observation.frameID <= last {
			if observation.frameID < last { reset() }
			return .needMore
		}
		lastFrameID = observation.frameID
		// Capture times must advance: reordered frames restart.
		if let last = lastAcceptedAt, observation.capturedAt <= last {
			reset()
			return .needMore
		}
		if windowStart == nil {
			windowStart = observation.capturedAt
		} else if let last = lastAcceptedAt, observation.capturedAt - last > maximumGap {
			windowStart = observation.capturedAt
		}
		lastAcceptedAt = observation.capturedAt
		guard let start = windowStart, let last = lastAcceptedAt else { return .needMore }
		return last - start >= requiredAbsence ? .absent : .needMore
	}
}

/// The final pre-lock conjunction, as data.
///
/// The watcher builds one from live state immediately before `ScreenLock` and
/// locks only when `allowsLock` holds. Every field fails safe: unknown session
/// state arrives as `sessionUnlockedAndActive == false`, a stopped or
/// superseded task arrives as `cancelled` or `generationCurrent == false`.
/// Kept separate from the gate so the truth table is testable without
/// hardware: the gate proves absence, this decides whether absence may lock.
package struct PresenceLockDecision: Equatable, Sendable {
	package var executionPermitsLocking: Bool
	package var permissionsGranted: Bool
	package var walkAwayEnabled: Bool
	package var paused: Bool
	package var cancelled: Bool
	package var generationCurrent: Bool
	package var sessionUnlockedAndActive: Bool
	package var inputIdle: Bool
	package var displayAssertionHeld: Bool
	package var absenceProven: Bool

	package init(
		executionPermitsLocking: Bool,
		permissionsGranted: Bool,
		walkAwayEnabled: Bool,
		paused: Bool,
		cancelled: Bool,
		generationCurrent: Bool,
		sessionUnlockedAndActive: Bool,
		inputIdle: Bool,
		displayAssertionHeld: Bool,
		absenceProven: Bool
	) {
		self.executionPermitsLocking = executionPermitsLocking
		self.permissionsGranted = permissionsGranted
		self.walkAwayEnabled = walkAwayEnabled
		self.paused = paused
		self.cancelled = cancelled
		self.generationCurrent = generationCurrent
		self.sessionUnlockedAndActive = sessionUnlockedAndActive
		self.inputIdle = inputIdle
		self.displayAssertionHeld = displayAssertionHeld
		self.absenceProven = absenceProven
	}

	package var allowsLock: Bool {
		executionPermitsLocking && permissionsGranted
			&& walkAwayEnabled && !paused && !cancelled && generationCurrent
			&& sessionUnlockedAndActive && inputIdle && !displayAssertionHeld && absenceProven
	}
}
