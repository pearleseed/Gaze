import Foundation
import GazeCore

@MainActor
package final class CameraSessionGate {
	package enum Scope: Sendable { case foreground, lockScreen }

	private let scope: Scope
	private let makeSession: @MainActor () -> AutofillSessionLease
	private var session: AutofillSessionLease?

	package init(scope: Scope, makeSession: @escaping @MainActor () -> AutofillSessionLease = { AutofillSessionLease() }) {
		self.scope = scope
		self.makeSession = makeSession
	}

	package func begin(onInvalidation: @escaping () -> Void) -> Bool {
		end()
		guard scope == .foreground else { return true }
		let session = makeSession()
		self.session = session
		session.onInvalidation = onInvalidation
		return session.isValid
	}

	package var isValid: Bool { scope == .lockScreen || session?.isValid == true }

	package func end() {
		let previous = session
		session = nil
		previous?.onInvalidation = nil
		previous?.invalidate()
	}
}
