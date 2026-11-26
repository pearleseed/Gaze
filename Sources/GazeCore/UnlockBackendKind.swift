import Foundation

package enum UnlockBackendKind: String, CaseIterable, Sendable {
	/// Recognition runs, but nothing is unlocked. The safe default and a usable way to
	/// test enrolment without touching system authentication at all.
	case none
	/// The stored password is replayed into the login window as keystrokes.
	case keystroke

	/// Backends that are safe to offer in Settings.
	package static let selectableCases: [UnlockBackendKind] = [.none, .keystroke]

	package var title: String {
		switch self {
		case .none: return "Recognition only"
		case .keystroke: return "Unlock my Mac"
		}
	}

	/// Icon for the choice row.
	package var symbol: String {
		switch self {
		case .none: return "eye.fill"
		case .keystroke: return "lock.open.fill"
		}
	}

	package var detail: String {
		switch self {
		case .none:
			return "See recognition working without wiring it to anything."
		case .keystroke:
			return """
				Enters your password for you when you're recognised. Touch ID keeps \
				working. Your password is stored on this Mac in recoverable form, which is \
				what makes this possible.
				"""
		}
	}
}
