import Foundation
import GazeRecognition
import Testing

@Suite("Recognition Math & Vector Normalization")
struct RecognitionMathTests {
	@Test func normalizationCosineAndInvalidVectorHandling() throws {
		let source = "generated-math-fixture"
		let unit = try #require(Faceprint.normalized([3, 4], source: source))
		#expect(unit.values == [0.6, 0.8])
		#expect(abs(unit.similarity(to: unit) - 1) < 0.000001)

		let opposite = Faceprint(values: unit.values.map { -$0 }, source: source)
		#expect(abs(unit.similarity(to: opposite) + 1) < 0.000001)
		#expect(unit.similarity(to: Faceprint(values: unit.values, source: "other")) == 0)
		#expect(unit.similarity(to: Faceprint(values: [1], source: source)) == 0)
		#expect(Faceprint.normalized([], source: source) == nil)
		#expect(Faceprint.normalized([0, 0], source: source) == nil)
		#expect(Faceprint.normalized([1, 0], source: "") == nil)
		#expect(Faceprint(values: [1, 0], source: "").similarity(to: Faceprint(values: [1, 0], source: "")) == 0)

		let landmarks = LandmarkEmbedder()
		#expect(landmarks.similarity(Faceprint(values: [1], source: source), Faceprint(values: [1], source: source)) == 0)

		for value: Float in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
			let invalid = Faceprint(values: [value, 1], source: source)
			#expect(Faceprint.normalized(invalid.values, source: source) == nil)
			#expect(invalid.similarity(to: unit) == 0)
			#expect(unit.similarity(to: invalid) == 0)
			#expect(landmarks.similarity(invalid, unit) == 0)
		}
	}

	@Test func generatedVectorsPreserveNormalizationAndSelfSimilarity() throws {
		let source = "generated-math-fixture"
		var state: UInt64 = 20260913
		func randomValue() -> Float {
			state = state &* 6364136223846793005 &+ 1442695040888963407
			return Float(Double(state >> 32) / Double(UInt32.max) * 2 - 1)
		}
		for count in [2, 128, 512] {
			for _ in 0..<40 {
				let raw = (0..<count).map { _ in randomValue() }
				var oldNorm: Float = 0
				for value in raw { oldNorm += value * value }
				oldNorm = sqrt(oldNorm)
				let normalized = try #require(Faceprint.normalized(raw, source: source))
				#expect(zip(normalized.values, raw.map { $0 / oldNorm }).allSatisfy { abs($0 - $1) <= 1e-6 })
				#expect(normalized.values.allSatisfy { $0.isFinite })
				#expect(abs(normalized.similarity(to: normalized) - 1) < 0.00001)
			}
		}
	}
}
