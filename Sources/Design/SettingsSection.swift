import SwiftUI

// MARK: - Section

/// A titled group of rows.
///
/// Sentence case, not caps. Uppercased letterspaced headers are an iOS convention that
/// macOS dropped in Ventura.
private struct NativeSettingsFormKey: EnvironmentKey {
	static let defaultValue = false
}

private struct SettingsGroupFillKey: EnvironmentKey {
	static let defaultValue = Theme.settingsGroupFill
}

extension EnvironmentValues {
	var nativeSettingsForm: Bool {
		get { self[NativeSettingsFormKey.self] }
		set { self[NativeSettingsFormKey.self] = newValue }
	}
	var settingsGroupFill: Color {
		get { self[SettingsGroupFillKey.self] }
		set { self[SettingsGroupFillKey.self] = newValue }
	}
}

struct SettingsSection<Content: View>: View {
	@Environment(\.nativeSettingsForm) private var nativeForm
	@Environment(\.settingsGroupFill) private var groupFill

	let title: String?
	var footer: String?
	var info: String?
	@ViewBuilder var content: Content

	init(title: String? = nil, footer: String? = nil, info: String? = nil, @ViewBuilder content: () -> Content) {
		self.title = title
		self.footer = footer
		self.info = info
		self.content = content()
	}

	var body: some View {
		if nativeForm {
			Section {
				content
			} header: {
				sectionHeader
			} footer: {
				if let footer, !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(footer) }
			}
		} else {
			legacyBody
		}
	}

	private var legacyBody: some View {
		VStack(alignment: .leading, spacing: 7) {
			// Secondary, not primary. A group title labels the rows under it; setting it in
			// full-strength white made it compete with the row labels it was introducing.
			sectionHeader
				.padding(.horizontal, 4)

			VStack(spacing: 0) {
				content
			}
			.glassSurface(fill: groupFill)

			if let footer, !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				Text(footer)
					.font(Typography.detail)
					.foregroundStyle(Theme.secondaryLabel)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.horizontal, 4)
			}
		}
	}

	@ViewBuilder private var sectionHeader: some View {
		if let title {
			HStack {
				Text(title)
					.font(Typography.groupTitle)
					.foregroundStyle(Theme.secondaryLabel)
				if let info, !info.isEmpty {
					Spacer()
					InfoButton(title: "About \(title)", opensOnHover: true) {
						Text(info)
					}
				}
			}
		}
	}
}

/// Hairline between rows, inset to line up with the labels rather than the group edge.
struct RowDivider: View {
	@Environment(\.nativeSettingsForm) private var nativeForm
	/// Rows with an icon tile need a deeper inset so the rule starts under the label.
	var inset: CGFloat = 51

	var body: some View {
		if !nativeForm {
		Rectangle()
			.fill(Theme.separator)
			.frame(height: 1)
			.padding(.leading, inset)
			.accessibilityHidden(true)
		}
	}
}

/// A rounded glass square holding an SF Symbol.
///
/// Rows of pure text are hard to scan — the eye has to read every line to find the one it
/// wants. A consistent icon column gives each row a shape you can navigate by.
///
/// The tile is light on the wallpaper rather than a block of colour on it: same frosted
/// surface as the group it sits in, one step brighter, with a hairline to catch the edge.
/// It reads as glass rather than as a sticker.
struct IconTile: View {
	let symbol: String
	/// Only ever passed for something that is reporting *state* — the enrolled face's
	/// warning triangle, a destructive row. Left alone otherwise.
	var tint: Color?
	var isEnabled = true

	var body: some View {
		// A glyph, not a badge.
		//
		// This drew each symbol on its own rounded, filled tile — a lighter square inside
		// an already-light group. System Settings does that in its *sidebar*, where the
		// tile's colour is what tells Wi-Fi from Bluetooth at a glance, and never in a
		// detail pane: there the icon is a bare glyph in the row's leading column. A grey
		// square behind a grey glyph adds a second rounded rectangle inside every row and
		// carries no information, since these tiles were all the same colour anyway.
		//
		// Bigger and secondary-weight to compensate: the tile was doing the work of making
		// a 13pt glyph findable, and size and tone do it instead.
		Image(systemName: symbol)
			.font(.system(size: 17, weight: .regular))
			.foregroundStyle(tint ?? Theme.secondaryLabel)
			.frame(width: 26, height: 26)
			.opacity(isEnabled ? 1 : 0.45)
			.accessibilityHidden(true)
	}
}
