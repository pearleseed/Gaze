import Foundation
import GazeCamera

package struct RecognitionMatchHold: Sendable {
	package private(set) var faceID: UUID?
	private var since: ContinuousClock.Instant?

	package init() {}

	package mutating func reset() {
		faceID = nil
		since = nil
	}

	package mutating func consume(faceID: UUID, now: ContinuousClock.Instant, required: Duration) -> Bool {
		if self.faceID != faceID || since.map({ now < $0 }) == true {
			self.faceID = faceID
			since = now
		}
		guard let since else { return false }
		return since.duration(to: now) >= required
	}
}

package struct RecognitionRejectionHold: Sendable {
	private var since: ContinuousClock.Instant?
	private var lastCapture: ContinuousClock.Instant?

	package init() {}

	package mutating func reset() {
		since = nil
		lastCapture = nil
	}

	package mutating func consume(capturedAt: ContinuousClock.Instant, required: Duration) -> Bool {
		guard required > .zero else { reset(); return false }
		if let previous = lastCapture,
			capturedAt <= previous || previous.duration(to: capturedAt) > CameraEvidenceContinuity.maximumGap {
			reset()
		}
		if since == nil { since = capturedAt }
		lastCapture = capturedAt
		guard let since else { return false }
		return since.duration(to: capturedAt) >= required
	}
}

package struct RecognitionFrameGate: Sendable {
	/// The lock-screen camera is cold after sleep and regularly took 3.6 s or more to
	/// deliver its first frame, so 4 s ended real attempts before a frame arrived.
	/// Waiting longer releases nothing: no frame, no evidence, no password.
	package static let firstFrameTimeout: Duration = .seconds(8)
	package static let runningFrameTimeout: Duration = .seconds(1)

	package enum Result: Equatable, Sendable {
		case waiting
		case fresh(continuous: Bool)
		case stalled
	}

	private var lastID: UInt64?
	private var lastCapture: ContinuousClock.Instant?
	private var lastAdvance: ContinuousClock.Instant
	private var didStall = false
	package var hasReceivedFrame: Bool { lastCapture != nil }

	package init(now: ContinuousClock.Instant = .now) { lastAdvance = now }

	package mutating func observe(id: UInt64, capturedAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Result {
		let timeout = hasReceivedFrame ? Self.runningFrameTimeout : Self.firstFrameTimeout
		guard !didStall, now >= lastAdvance, lastAdvance.duration(to: now) <= timeout else {
			didStall = true
			return .stalled
		}
		guard let capturedAt, capturedAt <= now,
			capturedAt.duration(to: now) <= CameraFrameLease.maximumAge,
			lastID != id, lastCapture.map({ capturedAt > $0 }) ?? true else {
			return .waiting
		}
		let continuous = lastCapture.map { $0.duration(to: capturedAt) <= CameraEvidenceContinuity.maximumGap } ?? false
		lastID = id
		lastCapture = capturedAt
		lastAdvance = now
		return .fresh(continuous: continuous)
	}
}
