import Foundation
import GazeRecognition
import Testing

@Suite("Face Avatar Model & Normalization")
struct FaceAvatarTests {
	@Test func paletteHasEightDistinctColorsWithoutGreen() {
		let cases = FaceAvatarColor.allCases
		#expect(cases.count == 8)
		#expect(Set(cases.map(\.rawValue)).count == 8)
		#expect(!cases.map(\.rawValue).contains("green"))
	}

	@Test func curatedEmojiListHasTwentyFourNormalizedEntries() {
		#expect(FaceAvatarText.curatedEmojis.count == 24)
		#expect(Set(FaceAvatarText.curatedEmojis).count == 24)
		for symbol in FaceAvatarText.curatedEmojis {
			#expect(FaceAvatarText.normalizedEmoji(symbol) == symbol)
		}
	}

	@Test func presetCodableRoundTrip() throws {
		let samples: [FaceAvatarPreset] = [
			.emoji(symbol: "🧑‍💻", color: .indigo),
			.emoji(symbol: "⭐️", color: .amber),
			.monogram(customText: nil, color: .blue),
			.monogram(customText: "VN", color: .coral),
		]

		let encoder = JSONEncoder()
		let decoder = JSONDecoder()

		for sample in samples {
			let data = try encoder.encode(sample)
			let decoded = try decoder.decode(FaceAvatarPreset.self, from: data)
			#expect(decoded == sample)
		}
	}

	@Test func initialsExtractUpToTwoWordsIncludingUnicode() {
		#expect(FaceAvatarText.initials(for: "Nam") == "N")
		#expect(FaceAvatarText.initials(for: "Đăng Khoa") == "ĐK")
		#expect(FaceAvatarText.initials(for: "  Alice   Bob  Carol ") == "AB")
		#expect(FaceAvatarText.initials(for: "   ") == "?")
		#expect(FaceAvatarText.initials(for: "") == "?")
	}

	@Test func monogramSanitizationTrimsUppercasesAndCapsAtTwoCharacters() {
		#expect(FaceAvatarText.sanitizedMonogram("  vn ") == "VN")
		#expect(FaceAvatarText.sanitizedMonogram("abc") == "AB")
		#expect(FaceAvatarText.sanitizedMonogram("  đăng ") == "ĐĂ")
		#expect(FaceAvatarText.sanitizedMonogram("a b") == "AB")
		#expect(FaceAvatarText.sanitizedMonogram("a\nb") == "AB")
		#expect(FaceAvatarText.sanitizedMonogram("ßa") == "SS")
		#expect(FaceAvatarText.sanitizedMonogram("a") == "A")
		#expect(FaceAvatarText.sanitizedMonogram("   \n\t ") == nil)
		#expect(FaceAvatarText.sanitizedMonogram("") == nil)
	}

	@Test func presetNormalizedSanitizesMonogramAndRejectsInvalidEmoji() {
		#expect(
			FaceAvatarPreset.monogram(customText: "   ", color: .blue).normalized()
				== .monogram(customText: nil, color: .blue)
		)
		#expect(
			FaceAvatarPreset.monogram(customText: " a b c ", color: .coral).normalized()
				== .monogram(customText: "AB", color: .coral)
		)
		#expect(
			FaceAvatarPreset.emoji(symbol: " 🧑‍💻 ", color: .indigo).normalized()
				== .emoji(symbol: "🧑‍💻", color: .indigo)
		)
		#expect(FaceAvatarPreset.emoji(symbol: "   ", color: .blue).normalized() == nil)
		#expect(FaceAvatarPreset.emoji(symbol: "abc", color: .blue).normalized() == nil)
	}

	@Test func emojiNormalizationPreservesZwjAndVariationSelectorsAndRejectsPlainText() {
		#expect(FaceAvatarText.normalizedEmoji(" 🧑‍💻 ") == "🧑‍💻")
		#expect(FaceAvatarText.normalizedEmoji("👩‍🎨") == "👩‍🎨")
		#expect(FaceAvatarText.normalizedEmoji("⭐️🚀") == "⭐️")
		#expect(FaceAvatarText.normalizedEmoji("☕️") == "☕️")
		#expect(FaceAvatarText.normalizedEmoji("🇻🇳") == "🇻🇳")
		#expect(FaceAvatarText.normalizedEmoji("1️⃣") == "1️⃣")
		#expect(FaceAvatarText.normalizedEmoji("👋🏽") == "👋🏽")
		#expect(FaceAvatarText.normalizedEmoji("🦊abc") == "🦊")
		#expect(FaceAvatarText.normalizedEmoji("abc🦊") == "🦊")
		#expect(FaceAvatarText.normalizedEmoji("123") == nil)
		#expect(FaceAvatarText.normalizedEmoji("abc") == nil)
		#expect(FaceAvatarText.normalizedEmoji("#*") == nil)
		#expect(FaceAvatarText.normalizedEmoji("   ") == nil)
	}
}
