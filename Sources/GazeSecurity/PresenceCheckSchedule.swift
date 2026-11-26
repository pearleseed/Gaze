import Foundation

/// Limits camera checks during an uninterrupted period without input.
package struct PresenceCheckSchedule: Sendable {
	package static let idleRequired: TimeInterval = 20
	package static let retryInterval: Duration = .seconds(30)
	private var nextCheck: ContinuousClock.Instant?

	package init() {}

	package mutating func permits(idleSeconds: TimeInterval, at now: ContinuousClock.Instant) -> Bool {
		guard idleSeconds.isFinite, idleSeconds >= 0 else { return false }
		guard idleSeconds >= Self.idleRequired else {
			nextCheck = nil
			return false
		}
		return nextCheck.map { now >= $0 } ?? true
	}

	package mutating func finished(at now: ContinuousClock.Instant) {
		nextCheck = now.advanced(by: Self.retryInterval)
	}
}
