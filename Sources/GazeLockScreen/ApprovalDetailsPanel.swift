import AppKit
import GazeDesign
import SwiftUI

/// What the person is consenting to, shown in full beside the notch while a
/// face approval check runs. The notch headline has room for one short line;
/// this does not.
package struct ApprovalDetails {
	/// The requester in full, never truncated.
	package let name: String
	/// What it asks for, e.g. "wants to make changes".
	package let action: String
	/// Labelled facts, e.g. ("Location", "~/Applications/Foo.app").
	package let rows: [(label: String, value: String)]

	package init(name: String, action: String, rows: [(label: String, value: String)]) {
		self.name = name
		self.action = action
		self.rows = rows
	}
}

/// The full consent details under the notch: who is asking, what for, where the
/// app lives and who signed it. Non-activating, so the prompt underneath keeps
/// its focus.
@MainActor
package final class ApprovalDetailsPanel {
	private var window: NSPanel?

	package init() {}

	package func show(_ details: ApprovalDetails, onDismiss: @escaping @MainActor () -> Void) {
		let content = ApprovalDetailsView(details: details, onDismiss: { [weak self] in
			onDismiss()
			self?.hide()
		})
		let host = NSHostingView(rootView: content)
		let size = host.fittingSize
		let panel = window ?? NSPanel(contentRect: NSRect(origin: .zero, size: size),
			styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		panel.isFloatingPanel = true
		panel.becomesKeyOnlyIfNeeded = true
		panel.level = .statusBar
		panel.backgroundColor = .clear
		panel.isOpaque = false
		panel.hasShadow = true
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
		panel.contentView = host
		if let screen = NSScreen.main {
			let frame = screen.frame
			// Below the notch panel's open height, centred like it.
			let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - 110 - size.height)
			panel.setFrame(NSRect(origin: origin, size: size), display: true)
		}
		window = panel
		panel.orderFrontRegardless()
	}

	package func hide() {
		window?.orderOut(nil)
	}
}

private struct ApprovalDetailsView: View {
	let details: ApprovalDetails
	let onDismiss: @MainActor () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			VStack(alignment: .leading, spacing: 2) {
				Text(details.name)
					.font(.system(size: 13, weight: .semibold))
					.lineLimit(2)
					.fixedSize(horizontal: false, vertical: true)
				Text(details.action)
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			ForEach(Array(details.rows.enumerated()), id: \.offset) { _, row in
				VStack(alignment: .leading, spacing: 1) {
					Text(row.label)
						.font(.system(size: 10, weight: .medium))
						.foregroundStyle(.secondary)
					Text(row.value)
						.font(.system(size: 11, weight: .medium))
						.lineLimit(2)
						.truncationMode(.middle)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			HStack {
				Text("Nod to approve")
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(.secondary)
				Spacer(minLength: 12)
				Button("Don't Allow", action: onDismiss)
					.buttonStyle(.borderless)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(.primary)
					.padding(.horizontal, 12)
					.padding(.vertical, 5)
					.background(Capsule().fill(Color.primary.opacity(0.1)))
			}
		}
		.foregroundStyle(.primary)
		.padding(16)
		.frame(width: 300, alignment: .leading)
		.gazeGlassPanel(cornerRadius: 22, castsShadow: false)
	}
}
