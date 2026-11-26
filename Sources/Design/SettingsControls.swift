import AppKit
import SwiftUI

// MARK: - Rows

/// A row with a title, optional explanation, and trailing control.
struct SettingRow<Trailing: View>: View {
	@Environment(\.nativeSettingsForm) private var nativeForm

	let title: String
	var detail: String?
	/// SF Symbol shown in a tinted tile at the leading edge.
	var symbol: String?
	var symbolTint: Color?
	/// A picture that stands in for the glyph — a person's portrait, an app's icon.
	///
	/// Only the credits rows pass one. Everywhere else the icon column is a shape to scan
	/// by and a photograph would be noise; on a list of people it is the opposite, because
	/// a face is the fastest way to tell one person from another and a row of identical
	/// grey glyphs is the slowest.
	var portrait: NSImage?
	var isEnabled = true
	@ViewBuilder var trailing: Trailing

	var body: some View {
		if nativeForm {
			LabeledContent {
				trailing
			} label: {
				HStack(spacing: 10) {
					if let portrait {
						Image(nsImage: portrait)
							.resizable()
							.scaledToFit()
							.frame(width: 26, height: 26)
							.accessibilityHidden(true)
					}
					VStack(alignment: .leading, spacing: 3) {
						Text(title)
						if let detail {
							Text(detail).font(.callout).foregroundStyle(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
				}
			}
			.disabled(!isEnabled)
		} else {
			legacyBody
		}
	}

	private var legacyBody: some View {
		HStack(spacing: 12) {
			if let portrait {
				// Rounded square, not a circle. Half of these are app icons, and macOS app
				// icons are squircles — circling them crops the artwork its designer chose.
				Image(nsImage: portrait)
					.resizable()
					.interpolation(.high)
					.aspectRatio(contentMode: .fill)
					.frame(width: 26, height: 26)
					.clipShape(.rect(cornerRadius: 6, style: .continuous))
					.opacity(isEnabled ? 1 : 0.45)
					.accessibilityHidden(true)
			} else if let symbol {
				IconTile(symbol: symbol, tint: symbolTint, isEnabled: isEnabled)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(Typography.row)
					.foregroundStyle(isEnabled ? Theme.label : Theme.tertiaryLabel)
					.fixedSize(horizontal: false, vertical: true)
				if let detail {
					Text(detail)
						.font(Typography.detail)
						.foregroundStyle(Theme.secondaryLabel)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 8)
			trailing
		}
		// System Settings' own row metrics. Its rows sit just under 50pt and are inset
		// further from the group's edge than 15pt — the density here was a touch tighter
		// than the system's everywhere, and being consistently a few points tight is the
		// kind of difference you read as "not quite right" without being able to name it.
		.padding(.horizontal, Theme.rowInset)
		.padding(.vertical, 11)
		.frame(minHeight: 48)
	}
}

/// A switch row.
struct SettingToggle: View {
	@Environment(\.nativeSettingsForm) private var nativeForm

	let title: String
	var detail: String?
	var symbol: String?
	var symbolTint: Color?
	var portrait: NSImage?
	var isEnabled = true
	@Binding var isOn: Bool

	var body: some View {
		if nativeForm {
			Toggle(isOn: $isOn) {
				Text(title)
				if let detail { Text(detail) }
			}
			.disabled(!isEnabled)
		} else {
			legacyBody
		}
	}

	private var legacyBody: some View {
		SettingRow(
			title: title, detail: detail, symbol: symbol, symbolTint: symbolTint,
			portrait: portrait,
			isEnabled: isEnabled
		) {
			Toggle(title, isOn: $isOn)
				.labelsHidden()
				.accessibilityLabel(title)
				.accessibilityHint(detail ?? "")
				.toggleStyle(.switch)
				.controlSize(.small)
				.tint(Theme.accent)
				.disabled(!isEnabled)
		}
	}
}

/// A short status line — readiness, lockout, warnings.
///
/// Plain text with a small coloured symbol, not a tinted banner. Full-width colour bars
/// inside a group shout at a volume the message rarely earns.
///
/// Named for what it is. It was `StatusPill`, and it has never been a pill — the same file
/// held a real capsule-backed pill in the recognition test, so the two names were the wrong
/// way round.
struct StatusLine: View {

	enum Kind {
		case ok, warning, error

		var tint: Color {
			switch self {
			case .ok: return Theme.faceID
			case .warning: return Theme.warning
			case .error: return Theme.danger
			}
		}

		var symbol: String {
			switch self {
			case .ok: return "checkmark.circle.fill"
			case .warning: return "exclamationmark.triangle.fill"
			case .error: return "xmark.circle.fill"
			}
		}

		/// Colour is the only thing separating these three on screen, which is no separation
		/// at all for a colour-blind user. Spoken, the severity has to be said.
		var accessibilityPrefix: String {
			switch self {
			case .ok: return ""
			case .warning: return "Warning: "
			case .error: return "Problem: "
			}
		}
	}

	let kind: Kind
	let message: String
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 7) {
			Image(systemName: kind.symbol)
				.font(Typography.caption)
				.foregroundStyle(kind.tint)
				// The readiness line flips between warning and error as unlock setup
				// changes underneath it, so the glyph rolls over rather than cutting.
				.contentTransition(.symbolEffect(.replace.downUp))
			Text(message)
				.font(Typography.detail)
				.foregroundStyle(Theme.secondaryLabel)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, Theme.rowInset)
		.padding(.vertical, 10)
		// The symbol is decoration for a message that already says it; without this,
		// VoiceOver reads "checkmark circle fill" before every status line.
		.accessibilityElement(children: .combine)
		.accessibilityLabel(Text(kind.accessibilityPrefix + message))
		.symbolEffectsRemoved(reduceMotion)
	}
}

/// A text field matching the group's surface.
struct SettingsField: View {
	let placeholder: String
	@Binding var text: String
	var isSecure = true

	var body: some View {
		Group {
			if isSecure {
				SecureField(placeholder, text: $text)
			} else {
				TextField(placeholder, text: $text)
			}
		}
		.textFieldStyle(.plain)
		.font(Typography.row)
		.padding(.horizontal, 14)
		.padding(.vertical, 7)
		// The system's glass, in a capsule — the same treatment `GlassField` gives the field
		// on the setup screen.
		//
		// This drew its own well: a rounded rectangle at radius 8, filled darker than the
		// group behind it, with a hairline round the edge. Two problems. It was the one
		// control in the window still hand-drawn, so on macOS 26 it sat in a row between a
		// real glass button and a real glass popup looking like neither; and it was the only
		// text field in the app that was not a capsule, so the password field in Settings and
		// the password field in setup — the same field, asking the same question — had
		// different shapes.
		//
		// `.glassEffect` is the real material, with the system's own focus ring, so there is
		// nothing left here to approximate.
		.glassEffect(.regular, in: .capsule)
	}
}

/// The app's push button.
///
/// The system's own button styles — `.bordered` for anything, `.borderedProminent` for the
/// one action a screen exists for — and nothing else. On macOS 26 these render as real
/// Liquid Glass, with the system's press, hover and focus behaviour for free; a hand-rolled
/// glass style could only ever approximate them, and the whole point is that a button here
/// reads as Apple's because it *is* Apple's.
///
/// No custom tint: buttons take the system accent, which keeps green reserved for the one
/// thing it means everywhere else in this app — *recognised*. A destructive button is a plain
/// `Button(role: .destructive)`, which the system already draws in red.
enum GazeButtonProminence {
	/// The action the screen exists for — at most one per screen. Filled (`.borderedProminent`).
	case primary
	/// Everything else. Bordered.
	case standard
}

extension View {
	/// Apply the app's standard push-button styling. `size` defaults to `.regular`; hero and
	/// setup actions take `.large`.
	func gazeButton(_ prominence: GazeButtonProminence = .standard, size: ControlSize = .regular)
		-> some View
	{
		modifier(GazeButtonModifier(prominence: prominence, size: size))
	}
}

struct GazeButtonModifier: ViewModifier {
	@Environment(\.nativeSettingsForm) private var nativeForm
	let prominence: GazeButtonProminence
	let size: ControlSize

	func body(content: Content) -> some View {
		if nativeForm {
			switch prominence {
			case .primary: content.buttonStyle(.borderedProminent).controlSize(size)
			case .standard: content.buttonStyle(.bordered).controlSize(size)
			}
		} else {
			legacyBody(content: content)
		}
	}

	private func legacyBody(content: Content) -> some View {
		Group {
			// `.glass` / `.glassProminent` are the Liquid Glass styles proper: a lensing,
			// refracting control rather than `.bordered`'s flat capsule with a glass-ish
			// fill. Same system press, hover and focus behaviour, same accent, and no
			// hand-rolled material — this is Apple's, which is the whole point.
			if #available(macOS 26.0, *) {
				switch prominence {
				case .primary: content.buttonStyle(.glassProminent)
				case .standard: content.buttonStyle(.glass)
				}
			} else {
				switch prominence {
				case .primary: content.buttonStyle(.borderedProminent)
				case .standard: content.buttonStyle(.bordered)
				}
			}
		}
		.controlSize(size)
		// Capsule, everywhere, stated once.
		//
		// `.glass` picks its own shape from the control's size, so a regular button came out
		// a rounded rectangle and a small one came out nearly a capsule — two shapes for the
		// same control, side by side in the same row on the credits and test panes. macOS 26
		// draws its own glass controls as capsules; matching that also means the app has one
		// button shape rather than a shape per size.
		.buttonBorderShape(.capsule)
	}
}

/// A choice shown as a native pop-up menu: a `Menu` holding an inline `Picker`.
///
/// One type for every "pick one of a few" row, so Face position, Movements and Theme share
/// the same sizing, typography and button treatment. The displayed value is the row's own
/// type scale with intrinsic sizing — no fixed width, so a longer value grows the capsule
/// instead of clipping.
struct SettingsChoiceMenu<Selection: Hashable, Options: View>: View {
	let title: String
	let valueLabel: String
	@Binding var selection: Selection
	@ViewBuilder var options: () -> Options

	var body: some View {
		Menu {
			Picker(title, selection: $selection) { options() }
				.pickerStyle(.inline)
		} label: {
			Text(valueLabel)
				.font(Typography.control)
				.lineLimit(1)
		}
		.menuStyle(.button)
		.buttonStyle(.glass)
		.buttonBorderShape(.capsule)
		.controlSize(.large)
		.accessibilityLabel(title)
		.accessibilityValue(valueLabel)
		.fixedSize()
	}
}

/// A setting with a few ordered steps, as a slider with the steps named under it.
///
/// Used where the choices run from one end to the other (close to far, relaxed to
/// strict), so where you are on the range reads at a glance. Clicking a step's name
/// jumps to it; the slider only writes when the step actually changes.
struct SettingsStepSlider<Value: Hashable>: View {
	let title: String
	let values: [Value]
	@Binding var selection: Value
	let label: (Value) -> String

	private var index: Int { values.firstIndex(of: selection) ?? 0 }

	private func select(_ newIndex: Int) {
		let value = values[min(values.count - 1, max(0, newIndex))]
		if value != selection { selection = value }
	}

	var body: some View {
		VStack(spacing: 2) {
			Slider(
				value: Binding(get: { Double(index) }, set: { select(Int($0.rounded())) }),
				in: 0...Double(max(1, values.count - 1)),
				step: 1)
				.controlSize(.small)
				.tint(Theme.label.opacity(0.85))
			HStack(spacing: 0) {
				ForEach(values.indices, id: \.self) { i in
					if i > 0 { Spacer(minLength: 4) }
					Text(label(values[i]))
						.font(Typography.caption)
						.foregroundStyle(i == index ? Theme.label : Theme.secondaryLabel)
						.contentShape(Rectangle())
						.onTapGesture { select(i) }
				}
			}
		}
		.frame(width: 200)
		// VoiceOver gets a picker of the named steps; a plain Slider reads out its index.
		.accessibilityRepresentation {
			Picker(title, selection: $selection) {
				ForEach(values, id: \.self) { Text(label($0)).tag($0) }
			}
		}
	}
}

/// The shared expandable-row treatment for the native `DisclosureGroup`s.
///
/// Label styling lives in `Theme.disclosureLabel(_:)`; this modifier carries the native
/// disclosure tint and the row padding. Inside a native `Form` it applies neither padding:
/// the form owns row insets there, and adding its own would double them.
struct SettingsDisclosureRowStyle: ViewModifier {
	@Environment(\.nativeSettingsForm) private var nativeForm

	func body(content: Content) -> some View {
		content
			.tint(Theme.secondaryLabel)
			.padding(.horizontal, nativeForm ? 0 : Theme.rowInset)
			.padding(.vertical, nativeForm ? 0 : 14)
	}
}

extension Theme {
	/// An expandable row's label: the row type scale in the primary label colour.
	static func disclosureLabel(_ title: String) -> some View {
		Text(title)
			.font(Typography.row)
			.foregroundStyle(Theme.label)
	}
}

extension View {
	func settingsDisclosureRow() -> some View {
		modifier(SettingsDisclosureRowStyle())
	}
}

/// A small ⓘ that opens a popover.
///
/// For the explanation that is too long to sit in a row's subtitle but too important to leave
/// in a file on GitHub. A footer under the group would hold it, but a footer is read by
/// nobody who has already decided — this is read by the person hesitating.
struct InfoButton<Content: View>: View {

	let title: String
	var opensOnHover = false
	@ViewBuilder var content: Content

	@State private var isShowing = false
	@State private var buttonHovered = false
	@State private var popoverHovered = false
	@State private var pinned = false
	@FocusState private var buttonFocused: Bool
	@FocusState private var popoverFocused: Bool
	// Keyboard focus and VoiceOver focus are separate systems; the popover needs both.
	@AccessibilityFocusState private var popoverVoiceOverFocused: Bool

	var body: some View {
		Button {
			if pinned {
				pinned = false
				isShowing = false
			} else {
				pinned = true
				isShowing = true
			}
		} label: {
			Image(systemName: "info.circle")
				.font(Typography.control)
				.foregroundStyle(Theme.secondaryLabel)
				.frame(minWidth: 22, minHeight: 22)
				.contentShape(.circle)
		}
		.buttonStyle(.plain)
		.help(title)
		.accessibilityLabel(title)
		.focused($buttonFocused)
		.onHover { buttonHovered = $0 }
		.popover(isPresented: $isShowing, arrowEdge: .bottom) {
			VStack(alignment: .leading, spacing: 10) {
				Text(title)
					.font(Typography.groupTitle)
					.foregroundStyle(Theme.label)
				content
					.font(Typography.detail)
					.foregroundStyle(Theme.secondaryLabel)
					.fixedSize(horizontal: false, vertical: true)
			}
			.multilineTextAlignment(.leading)
			.padding(16)
			.frame(width: 300)
			// Focusable so keyboard and VoiceOver users can reach the explanation, but
			// without the ring macOS draws around a focusable container — a blue box
			// around a paragraph of help text reads as an error, not as focus.
			.focusable()
			.focusEffectDisabled()
			.focused($popoverFocused)
			.accessibilityElement(children: .combine)
			.accessibilityFocused($popoverVoiceOverFocused)
			.onHover { popoverHovered = $0 }
		}
		.task(id: buttonHovered || popoverHovered) {
			guard opensOnHover else { return }
			let hovering = buttonHovered || popoverHovered
			do { try await Task.sleep(for: .milliseconds(hovering ? 350 : 250)) }
			catch { return }
			guard !pinned else { return }
			isShowing = hovering
		}
		.onChange(of: isShowing) { _, shown in
			// Escape and outside-clicks dismiss via the binding, so focus is restored here rather than in key handling.
			if shown { popoverFocused = true; popoverVoiceOverFocused = true } else {
				let hadFocus = popoverFocused
				pinned = false; popoverHovered = false
				if hadFocus { buttonFocused = true }
			}
		}
		.onDisappear { isShowing = false; pinned = false }
	}
}
