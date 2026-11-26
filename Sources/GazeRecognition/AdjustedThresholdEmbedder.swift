import Foundation
import GazeCamera

/// Shifts the base embedder's match threshold by a sensitivity offset.
///
/// Prints stay in the base feature space: `identifier`, `usesCosineSimilarity`,
/// `embed` and `similarity` all forward untouched, so enrolments recorded under
/// the base identifier keep comparing. Only the acceptance line moves, clamped
/// to 0.3...0.7.
package struct AdjustedThresholdEmbedder: FaceEmbedder, Sendable {
	package let base: any FaceEmbedder
	package let offset: Float

	package init(base: any FaceEmbedder, offset: Float) {
		self.base = base
		self.offset = offset
	}

	package var identifier: String { base.identifier }
	package var usesCosineSimilarity: Bool { base.usesCosineSimilarity }
	package var matchThreshold: Float { min(0.7, max(0.3, base.matchThreshold + offset)) }

	package func embed(_ sample: FaceSample) -> Faceprint? { base.embed(sample) }
	package func embedUpperFace(_ sample: FaceSample) -> Faceprint? { base.embedUpperFace(sample) }
	package func similarity(_ a: Faceprint, _ b: Faceprint) -> Float { base.similarity(a, b) }
	package func warmUp() { base.warmUp() }
}
