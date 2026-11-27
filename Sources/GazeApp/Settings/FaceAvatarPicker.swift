import AppKit
import SwiftUI
import GazeDesign
import GazeRecognition

/// Colour definitions for native Emoji pastel backdrops and Monogram gradients.
enum FaceAvatarPalette {
	static func emojiGradient(for color: FaceAvatarColor) -> LinearGradient {
		let pair: (Color, Color) = switch color {
		case .slate: (Color(red: 0.90, green: 0.92, blue: 0.95), Color(red: 0.80, green: 0.84, blue: 0.90))
		case .blue: (Color(red: 0.86, green: 0.92, blue: 1.00), Color(red: 0.74, green: 0.85, blue: 0.99))
		case .indigo: (Color(red: 0.88, green: 0.90, blue: 1.00), Color(red: 0.78, green: 0.81, blue: 0.98))
		case .purple: (Color(red: 0.93, green: 0.90, blue: 1.00), Color(red: 0.85, green: 0.80, blue: 0.98))
		case .pink: (Color(red: 0.99, green: 0.90, blue: 0.95), Color(red: 0.97, green: 0.79, blue: 0.89))
		case .coral: (Color(red: 1.00, green: 0.91, blue: 0.87), Color(red: 0.99, green: 0.81, blue: 0.73))
		case .amber: (Color(red: 1.00, green: 0.95, blue: 0.80), Color(red: 0.99, green: 0.88, blue: 0.62))
		case .teal: (Color(red: 0.84, green: 0.96, blue: 0.96), Color(red: 0.70, green: 0.90, blue: 0.91))
		}
		return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
	}

	static func monogramGradient(for color: FaceAvatarColor) -> LinearGradient {
		let pair: (Color, Color) = switch color {
		case .slate: (Color(red: 0.47, green: 0.52, blue: 0.59), Color(red: 0.31, green: 0.36, blue: 0.43))
		case .blue: (Color(red: 0.24, green: 0.55, blue: 0.98), Color(red: 0.13, green: 0.38, blue: 0.86))
		case .indigo: (Color(red: 0.42, green: 0.43, blue: 0.96), Color(red: 0.29, green: 0.28, blue: 0.82))
		case .purple: (Color(red: 0.62, green: 0.40, blue: 0.96), Color(red: 0.48, green: 0.24, blue: 0.82))
		case .pink: (Color(red: 0.94, green: 0.34, blue: 0.62), Color(red: 0.79, green: 0.18, blue: 0.48))
		case .coral: (Color(red: 0.96, green: 0.44, blue: 0.34), Color(red: 0.83, green: 0.26, blue: 0.21))
		case .amber: (Color(red: 0.96, green: 0.66, blue: 0.14), Color(red: 0.83, green: 0.48, blue: 0.05))
		case .teal: (Color(red: 0.14, green: 0.68, blue: 0.75), Color(red: 0.07, green: 0.51, blue: 0.60))
		}
		return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
	}
}

/// Circular avatar badge rendered natively in SwiftUI for photos, Emoji presets,
/// Monogram presets (dynamically tracking `faceName` when `customText == nil`),
/// and Gaze's default neutral initials fallback.
struct FaceAvatarView: View {
	let avatar: FaceAvatar
	let faceName: String
	var size: CGFloat = 52

	var body: some View {
		ZStack {
			switch avatar {
			case .photo(let image):
				Image(nsImage: image)
					.resizable()
					.interpolation(.high)
					.aspectRatio(contentMode: .fill)
					.frame(width: size, height: size)
					.clipShape(.circle)

			case .preset(.emoji(let symbol, let color)):
				Circle()
					.fill(FaceAvatarPalette.emojiGradient(for: color))
					.overlay {
						Text(symbol)
							.font(.system(size: size * 0.54))
							.lineLimit(1)
							.minimumScaleFactor(0.5)
					}

			case .preset(.monogram(let customText, let color)):
				let label = customText.flatMap(FaceAvatarText.sanitizedMonogram) ?? FaceAvatarText.initials(for: faceName)
				Circle()
					.fill(FaceAvatarPalette.monogramGradient(for: color))
					.overlay {
						Text(label)
							.font(.system(size: size * 0.40, weight: .semibold, design: .rounded))
							.foregroundStyle(.white)
							.lineLimit(1)
							.minimumScaleFactor(0.6)
							.padding(.horizontal, size * 0.12)
					}

			case .initials:
				Circle()
					.fill(Theme.surface)
					.overlay {
						Text(FaceAvatarText.initials(for: faceName))
							.font(.system(size: size * 0.40, weight: .medium, design: .rounded))
							.foregroundStyle(Theme.secondaryLabel)
							.lineLimit(1)
							.minimumScaleFactor(0.6)
							.padding(.horizontal, size * 0.12)
					}
			}
		}
		.frame(width: size, height: size)
		.overlay { Circle().strokeBorder(Theme.separator, lineWidth: 1) }
	}
}

/// Compact macOS popover for picking a native Emoji or Monogram avatar, choosing a
/// custom photo from disk, or resetting back to default neutral initials.
struct FaceAvatarPicker: View {
	private enum Tab: String, CaseIterable, Identifiable {
		case emoji = "Emoji"
		case monogram = "Monogram"
		var id: String { rawValue }
	}

	let faceName: String
	let currentAvatar: FaceAvatar
	let onSelectPreset: (FaceAvatarPreset) -> Void
	let onChoosePhoto: () -> Void
	let onReset: () -> Void

	@State private var selectedTab: Tab
	@State private var selectedEmoji: String
	@State private var selectedColor: FaceAvatarColor
	@State private var customEmojiInput = ""
	@State private var monogramDraft: String
	@State private var pendingCharacterPalette = false
	@FocusState private var emojiFieldFocused: Bool
	@FocusState private var monogramFieldFocused: Bool

	private let emojiColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

	init(
		faceName: String,
		currentAvatar: FaceAvatar,
		onSelectPreset: @escaping (FaceAvatarPreset) -> Void,
		onChoosePhoto: @escaping () -> Void,
		onReset: @escaping () -> Void
	) {
		self.faceName = faceName
		self.currentAvatar = currentAvatar
		self.onSelectPreset = onSelectPreset
		self.onChoosePhoto = onChoosePhoto
		self.onReset = onReset

		switch currentAvatar.preset {
		case .emoji(let symbol, let color):
			_selectedTab = State(initialValue: .emoji)
			_selectedEmoji = State(initialValue: symbol)
			_selectedColor = State(initialValue: color)
			_monogramDraft = State(initialValue: "")
		case .monogram(let customText, let color):
			_selectedTab = State(initialValue: .monogram)
			_selectedEmoji = State(initialValue: FaceAvatarText.curatedEmojis[0])
			_selectedColor = State(initialValue: color)
			_monogramDraft = State(initialValue: customText ?? "")
		case nil:
			_selectedTab = State(initialValue: .emoji)
			_selectedEmoji = State(initialValue: FaceAvatarText.curatedEmojis[0])
			_selectedColor = State(initialValue: .blue)
			_monogramDraft = State(initialValue: "")
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Picker("Avatar style", selection: $selectedTab) {
				ForEach(Tab.allCases) { tab in
					Text(tab.rawValue).tag(tab)
				}
			}
			.pickerStyle(.segmented)
			.labelsHidden()

			switch selectedTab {
			case .emoji:
				emojiTab
			case .monogram:
				monogramTab
			}

			colorSwatches

			Divider()

			HStack(spacing: 8) {
				Button("Choose Photo…", action: onChoosePhoto)
					.controlSize(.small)

				Spacer(minLength: 4)

				if currentAvatar.isCustomized {
					Button("Reset", role: .destructive, action: onReset)
						.buttonStyle(.plain)
						.font(Typography.control)
						.foregroundStyle(Theme.danger)
				}
			}
		}
		.padding(14)
		.frame(width: 276)
		.onChange(of: currentAvatar.preset) { _, preset in
			syncFromPreset(preset)
		}
	}

	// MARK: - Emoji Tab

	private var emojiTab: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Button {
					applyEmoji(selectedEmoji)
				} label: {
					FaceAvatarView(
						avatar: .preset(.emoji(symbol: selectedEmoji, color: selectedColor)),
						faceName: faceName,
						size: 36)
				}
				.buttonStyle(.plain)
				.help("Apply \(selectedEmoji)")
				.accessibilityLabel("Apply \(selectedEmoji) avatar")

				TextField("Pick any emoji…", text: $customEmojiInput)
					.textFieldStyle(.roundedBorder)
					.controlSize(.small)
					.focused($emojiFieldFocused)
					.onChange(of: emojiFieldFocused) { _, focused in
						guard focused, pendingCharacterPalette else { return }
						pendingCharacterPalette = false
						Task { @MainActor in
							NSApp.orderFrontCharacterPalette(nil)
						}
					}
					.onChange(of: customEmojiInput) { _, value in
						guard let normalized = FaceAvatarText.normalizedEmoji(value) else { return }
						selectedEmoji = normalized
						applyEmoji(normalized)
						customEmojiInput = ""
					}

				Button {
					if emojiFieldFocused {
						NSApp.orderFrontCharacterPalette(nil)
					} else {
						pendingCharacterPalette = true
						emojiFieldFocused = true
					}
				} label: {
					Image(systemName: "face.smiling")
						.font(.system(size: 13))
						.frame(width: 24, height: 22)
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.help("Open macOS Emoji Picker")
				.accessibilityLabel("Open macOS Emoji Picker")
			}

			LazyVGrid(columns: emojiColumns, spacing: 6) {
				ForEach(FaceAvatarText.curatedEmojis, id: \.self) { symbol in
					let isSelected: Bool = {
						if case .emoji(let activeSymbol, _) = currentAvatar.preset {
							return activeSymbol == symbol
						}
						return false
					}()
					Button {
						selectedEmoji = symbol
						applyEmoji(symbol)
					} label: {
						Text(symbol)
							.font(.system(size: 20))
							.frame(width: 34, height: 34)
							.background(
								Circle()
									.fill(isSelected ? Theme.selection : Theme.hoverFill)
							)
							.overlay {
								if isSelected {
									Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
								}
							}
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Emoji \(symbol)")
					.accessibilityAddTraits(isSelected ? .isSelected : [])
				}
			}
		}
	}

	// MARK: - Monogram Tab

	private var monogramTab: some View {
		let sanitized = FaceAvatarText.sanitizedMonogram(monogramDraft)
		let candidate: FaceAvatarPreset = .monogram(customText: sanitized, color: selectedColor)
		let isApplied = currentAvatar.preset == candidate

		return VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 12) {
				Button {
					applyMonogram()
				} label: {
					FaceAvatarView(
						avatar: .preset(candidate),
						faceName: faceName,
						size: 56)
				}
				.buttonStyle(.plain)
				.help("Apply monogram")
				.accessibilityLabel("Apply monogram")

				VStack(alignment: .leading, spacing: 5) {
					TextField(FaceAvatarText.initials(for: faceName), text: $monogramDraft)
						.textFieldStyle(.roundedBorder)
						.controlSize(.small)
						.focused($monogramFieldFocused)
						.accessibilityLabel("Monogram letters")
						.onChange(of: monogramDraft) { _, _ in
							// Never mutate `monogramDraft` mid-edit so Vietnamese/CJK IME marked
							// text completes cleanly; normalize on commit or focus loss instead.
							guard monogramFieldFocused else { return }
							let next: FaceAvatarPreset = .monogram(
								customText: FaceAvatarText.sanitizedMonogram(monogramDraft),
								color: selectedColor)
							if currentAvatar.preset != next {
								onSelectPreset(next)
							}
						}
						.onSubmit {
							normalizeMonogramDraft()
							applyMonogram()
						}
						.onChange(of: monogramFieldFocused) { _, focused in
							if !focused { normalizeMonogramDraft() }
						}

					Text("Leave blank to follow face name.")
						.font(Typography.caption)
						.foregroundStyle(Theme.secondaryLabel)
						.fixedSize(horizontal: false, vertical: true)
				}
			}

			if !isApplied {
				Button("Use Monogram") {
					normalizeMonogramDraft()
					applyMonogram()
				}
				.controlSize(.small)
			}
		}
		.padding(.vertical, 4)
	}

	// MARK: - Colour Swatches

	private var colorSwatches: some View {
		HStack(spacing: 0) {
			ForEach(FaceAvatarColor.allCases) { color in
				let isActivePresetColor = isColorActiveOnCurrentTab(color)
				let isStagedColor = selectedColor == color
				Button {
					selectedColor = color
					switch selectedTab {
					case .emoji:
						applyEmoji(selectedEmoji)
					case .monogram:
						applyMonogram()
					}
				} label: {
					Circle()
						.fill(
							selectedTab == .emoji
								? FaceAvatarPalette.emojiGradient(for: color)
								: FaceAvatarPalette.monogramGradient(for: color)
						)
						.frame(width: 22, height: 22)
						.overlay {
							Circle().strokeBorder(
								isActivePresetColor
									? Color.accentColor
									: (isStagedColor ? Theme.secondaryLabel : Theme.separator),
								lineWidth: isActivePresetColor ? 2 : (isStagedColor ? 1.5 : 1))
						}
						.padding(2)
				}
				.buttonStyle(.plain)
				.accessibilityLabel("\(color.accessibilityName) background")
				.accessibilityAddTraits(isActivePresetColor ? .isSelected : [])

				if color != FaceAvatarColor.allCases.last {
					Spacer(minLength: 0)
				}
			}
		}
	}

	// MARK: - Helpers

	private func isColorActiveOnCurrentTab(_ color: FaceAvatarColor) -> Bool {
		switch (selectedTab, currentAvatar.preset) {
		case (.emoji, .emoji(_, let activeColor)): activeColor == color
		case (.monogram, .monogram(_, let activeColor)): activeColor == color
		default: false
		}
	}

	private func syncFromPreset(_ preset: FaceAvatarPreset?) {
		switch preset {
		case .emoji(let symbol, let color):
			selectedEmoji = symbol
			selectedColor = color
		case .monogram(let customText, let color):
			selectedColor = color
			if !monogramFieldFocused {
				monogramDraft = customText ?? ""
			}
		case nil:
			if !monogramFieldFocused {
				monogramDraft = ""
			}
		}
	}

	private func normalizeMonogramDraft() {
		let normalized = FaceAvatarText.sanitizedMonogram(monogramDraft) ?? ""
		if monogramDraft != normalized {
			monogramDraft = normalized
		}
	}

	private func applyEmoji(_ symbol: String) {
		onSelectPreset(.emoji(symbol: symbol, color: selectedColor))
	}

	private func applyMonogram() {
		onSelectPreset(.monogram(customText: FaceAvatarText.sanitizedMonogram(monogramDraft), color: selectedColor))
	}
}
