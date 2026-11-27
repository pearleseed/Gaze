import Foundation
import Observation

/// Opens Settings on a requested pane and section from outside a view.
///
/// A notification click cannot reach `@Environment(\.openWindow)` or SettingsView's pane
/// state, so it leaves a request here and presents Settings through the closure a live view
/// stored. SettingsView observes `pending`, selects the pane and reveals the section, then
/// clears it. Deliberately free of app types (pane and section travel as strings, and the
/// presentation closure is injected by a view) so tests can compile this without the app scene.
@MainActor
@Observable
package final class SettingsNavigator {
	package static let shared = SettingsNavigator()

	package struct Request: Equatable, Sendable {
		/// A `SettingsPane` raw value.
		package let pane: String
		/// The `ScrollViewReader` anchor, e.g. "updatesSection".
		package let section: String
		/// Bumps on every request so repeating the same destination still observes a change.
		package let token: UInt64

		package init(pane: String, section: String, token: UInt64) {
			self.pane = pane
			self.section = section
			self.token = token
		}
	}

	package var pending: Request?
	/// Presents Settings, bringing the app forward first. Stored by an always-alive view.
	package var presentSettings: (() -> Void)?

	private var nextToken: UInt64 = 0

	package init() {}

	package func openUpdates() {
		nextToken &+= 1
		pending = Request(pane: "general", section: "updatesSection", token: nextToken)
		presentSettings?()
	}
}
