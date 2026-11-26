import Foundation

package struct CameraEvidenceContinuity: Sendable {
	package private(set) var revision: UInt64 = 0
	private var capturedAt: ContinuousClock.Instant?
	private var usable = false
	package static let maximumGap: Duration = .milliseconds(240)

	package init() {}

	package mutating func invalidate() {
		revision &+= 1
		capturedAt = nil
		usable = false
	}

	@discardableResult
	package mutating func record(
		usable: Bool,
		capturedAt: ContinuousClock.Instant,
		droppedBefore: Int = 0
	) -> Bool {
		if let previous = self.capturedAt, capturedAt <= previous {
			revision &+= 1
			self.usable = false
			return false
		}
		if droppedBefore > 0 {
			invalidate()
		}
		if !usable || self.capturedAt.map({ $0.duration(to: capturedAt) > Self.maximumGap }) == true {
			revision &+= 1
		}
		self.capturedAt = capturedAt
		self.usable = usable
		return true
	}

	package func permits(_ revision: UInt64, at now: ContinuousClock.Instant) -> Bool {
		guard self.revision == revision, usable, let capturedAt else { return false }
		return capturedAt <= now && capturedAt.duration(to: now) <= CameraFrameLease.maximumAge
	}
}
