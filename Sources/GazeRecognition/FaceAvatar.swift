import AppKit
import Foundation

/// Background tones available for native Emoji and Monogram face avatars.
///
/// Green is intentionally omitted: green (`Theme.faceID`) is reserved across
/// Gaze for recognition events rather than static identity chrome.
package enum FaceAvatarColor: String, Codable, Sendable, CaseIterable, Identifiable {
	case slate
	case blue
	case indigo
	case purple
	case pink
	case coral
	case amber
	case teal

	package var id: String { rawValue }

	package var accessibilityName: String {
		switch self {
		case .slate: "Slate"
		case .blue: "Blue"
		case .indigo: "Indigo"
		case .purple: "Purple"
		case .pink: "Pink"
		case .coral: "Coral"
		case .amber: "Amber"
		case .teal: "Teal"
		}
	}
}

/// Persistent preset configuration stored alongside portraits in `Portraits/<id>.avatar.json`.
package enum FaceAvatarPreset: Codable, Equatable, Sendable {
	/// An Apple Color Emoji rendered over a soft pastel gradient circle.
	case emoji(symbol: String, color: FaceAvatarColor)
	/// Monogram initials rendered over a macOS-style circular gradient.
	///
	/// When `customText` is `nil`, the tile derives initials live from `face.name`
	/// so renaming the face updates the monogram automatically.
	case monogram(customText: String?, color: FaceAvatarColor)

	package var color: FaceAvatarColor {
		switch self {
		case .emoji(_, let color), .monogram(_, let color): color
		}
	}

	/// Returns a canonicalized preset, or `nil` when an emoji preset carries no valid emoji.
	package func normalized() -> FaceAvatarPreset? {
		switch self {
		case .emoji(let symbol, let color):
			guard let valid = FaceAvatarText.normalizedEmoji(symbol) else { return nil }
			return .emoji(symbol: valid, color: color)
		case .monogram(let customText, let color):
			return .monogram(customText: customText.flatMap(FaceAvatarText.sanitizedMonogram), color: color)
		}
	}
}

/// Resolved visual avatar for an enrolled face tile.
package enum FaceAvatar {
	case photo(NSImage)
	case preset(FaceAvatarPreset)
	/// Default neutral `Theme.surface` circle displaying the face's initials.
	case initials

	package var isCustomized: Bool {
		if case .initials = self { return false }
		return true
	}

	package var preset: FaceAvatarPreset? {
		if case .preset(let preset) = self { return preset }
		return nil
	}

	package var photo: NSImage? {
		if case .photo(let image) = self { return image }
		return nil
	}
}

/// Text & emoji normalization helpers shared by the avatar model, tile, and picker.
package enum FaceAvatarText {
	/// 24 curated Apple Color Emojis that stay legible at 52pt.
	package static let curatedEmojis: [String] = [
		"🦊", "🐱", "🐼", "🐻", "🐨", "🦁",
		"😎", "😊", "🥳", "🤓", "🤠", "👻",
		"🧑‍💻", "👩‍🎨", "🕵️", "🥷", "🤖", "👾",
		"🚀", "⭐️", "🎧", "🌿", "☕️", "💎",
	]

	/// One letter, or two when the name has multiple words.
	package static func initials(for name: String) -> String {
		let words = name.split(whereSeparator: \.isWhitespace)
		let letters = words.prefix(2).compactMap(\.first)
		guard !letters.isEmpty else { return "?" }
		return String(letters).uppercased()
	}

	/// Strips whitespace/newlines, uppercases, and caps custom monogram input at two grapheme clusters.
	package static func sanitizedMonogram(_ raw: String) -> String? {
		let compact = raw.filter { !$0.isWhitespace && !$0.isNewline }
		guard !compact.isEmpty else { return nil }
		return String(compact.uppercased().prefix(2))
	}

	/// Extracts the first full emoji grapheme cluster (preserving ZWJ and variation selectors).
	package static func normalizedEmoji(_ raw: String) -> String? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let match = trimmed.first(where: isEmojiCharacter) else { return nil }
		return String(match)
	}

	private static func isEmojiCharacter(_ character: Character) -> Bool {
		let scalars = character.unicodeScalars
		guard scalars.contains(where: { $0.properties.isEmoji }) else { return false }
		if scalars.contains(where: { $0.properties.isEmojiPresentation }) {
			return true
		}
		if scalars.count >= 2 && scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
			return true
		}
		return scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 })
	}
}
