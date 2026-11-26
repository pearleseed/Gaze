import CoreGraphics

package struct LockScreenInputSnapshot: Equatable, Sendable {
	package let keys: UInt32
	package let leftClicks: UInt32
	package let rightClicks: UInt32

	package init(keys: UInt32, leftClicks: UInt32, rightClicks: UInt32) {
		self.keys = keys
		self.leftClicks = leftClicks
		self.rightClicks = rightClicks
	}

	package static func current() -> Self {
		Self(
			keys: CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown),
			leftClicks: CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDown),
			rightClicks: CGEventSource.counterForEventType(.hidSystemState, eventType: .rightMouseDown))
	}
}

package struct LockScreenInputGuard: Sendable {
	private let initial: LockScreenInputSnapshot
	package private(set) var wasInterrupted = false

	package init(initial: LockScreenInputSnapshot) { self.initial = initial }

	package mutating func permits(_ current: LockScreenInputSnapshot) -> Bool {
		if current != initial { wasInterrupted = true }
		return !wasInterrupted
	}
}
