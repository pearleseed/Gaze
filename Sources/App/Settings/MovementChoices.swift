import SwiftUI

/// The movements Gaze may ask for, as plain checkboxes on one line. The last one on
/// cannot be turned off, so there is always something to ask for.
struct MovementChoices: View {
	@Binding var disabled: Set<String>

	private static let choices: [(id: String, title: String, detail: String)] = [
		("turn", "Turn", "Turn your head left or right"),
		("nod", "Nod", "Nod your head"),
		("blink", "Blink", "Blink"),
		("openMouth", "Open mouth", "Open your mouth"),
		("followLight", "Follow the light", "Follow a light on the screen with your eyes. Works best close to the screen."),
	]

	var body: some View {
		HStack(spacing: 18) {
			ForEach(Self.choices, id: \.id) { choice in
				let isOn = !disabled.contains(choice.id)
				let isLast = isOn && Self.choices.count - disabled.count == 1
				Toggle(choice.title, isOn: Binding(
					get: { isOn },
					set: { on in
						if on { disabled.remove(choice.id) }
						else if !isLast { disabled.insert(choice.id) }
					}))
				.toggleStyle(.checkbox)
				// Not disabled: a greyed tick reads as "off". Unticking the last one just
				// doesn't take.
				.help(isLast ? "At least one movement stays on" : choice.detail)
			}
		}
		.font(Typography.row)
	}
}

/// Unlock on first match, chosen separately for each movement setting.
struct InstantUnlockChoices: View {
	@Bindable var settings: Preferences

	var body: some View {
		HStack(spacing: 6) {
			ForEach(Preferences.UnlockMovementCount.allCases, id: \.self) { count in
				let _ = settings.instantUnlockRevision
				Toggle(count.shortTitle, isOn: Binding(
					get: { settings.instantUnlock(for: count) },
					set: { settings.setInstantUnlock($0, for: count) }))
					.toggleStyle(.button)
					.buttonBorderShape(.capsule)
					.controlSize(.small)
					.help("Unlock on first match when movements are set to \(count.shortTitle)")
			}
		}
		.fixedSize()
	}
}
