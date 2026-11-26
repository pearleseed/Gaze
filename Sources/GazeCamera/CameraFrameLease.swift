import Foundation

package struct CameraFrameLease: Sendable {
	package private(set) var generation: UUID?
	package static let maximumAge: Duration = .milliseconds(500)

	package init() {}

	package mutating func begin() -> UUID {
		let identifier = UUID()
		generation = identifier
		return identifier
	}

	package mutating func stop() { generation = nil }

	package func accepts(_ identifier: UUID, capturedAt: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Bool {
		generation == identifier && capturedAt <= now && capturedAt.duration(to: now) <= Self.maximumAge
	}
}
