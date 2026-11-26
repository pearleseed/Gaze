import Accelerate
import CoreML
import CoreVideo
import Foundation
import GazeCamera
import Synchronization
import Vision

/// A fixed-length numeric description of a face, comparable by cosine similarity.
package struct Faceprint: Codable, Sendable, Equatable {
	package var values: [Float]
	/// Which embedder produced it. Prints from different embedders are never comparable.
	package var source: String

	package init(values: [Float], source: String) {
		self.values = values
		self.source = source
	}

	package static func normalized(_ values: [Float], source: String) -> Faceprint? {
		guard !source.isEmpty, !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
		var energy: Float = 0
		vDSP_svesq(values, 1, &energy, vDSP_Length(values.count))
		guard energy.isFinite, energy > 0 else { return nil }
		var norm = sqrt(energy)
		var normalized = [Float](repeating: 0, count: values.count)
		vDSP_vsdiv(values, 1, &norm, &normalized, 1, vDSP_Length(values.count))
		return Faceprint(values: normalized, source: source)
	}

	/// Cosine similarity, 0...1 for learned embeddings (all produce non-negative prints
	/// or are L2-normalised, so negative similarity means the inputs are unrelated).
	///
	/// Do not call this directly on landmark prints: cosine is wrong for them (nearly
	/// identical canonical positions score ~1.0 for anyone). Use
	/// `FaceEmbedder.similarity(_:_:)` via dynamic dispatch instead.
	package func similarity(to other: Faceprint) -> Float {
		if source.hasPrefix("landmark") || other.source.hasPrefix("landmark") {
			assertionFailure("Use FaceEmbedder.similarity(_:_:) via dynamic dispatch — Faceprint.similarity(to:) is cosine-only and wrong for landmark prints.")
			return 0
		}
		guard !source.isEmpty, source == other.source, !values.isEmpty,
			values.count == other.values.count else { return 0 }
		let count = vDSP_Length(values.count)
		var dot: Float = 0, a: Float = 0, b: Float = 0
		vDSP_dotpr(values, 1, other.values, 1, &dot, count)
		vDSP_svesq(values, 1, &a, count)
		vDSP_svesq(other.values, 1, &b, count)
		guard dot.isFinite, a.isFinite, b.isFinite, a > 0, b > 0 else { return 0 }
		let denom = sqrt(a) * sqrt(b)
		guard denom.isFinite, denom > 0 else { return 0 }
		let score = dot / denom
		return score.isFinite ? score : 0
	}
}

package protocol FaceEmbedder: Sendable {
	var identifier: String { get }
	/// Opts into normalized vector matching. Custom metrics default to dynamic dispatch.
	var usesCosineSimilarity: Bool { get }
	/// The similarity above which two prints are considered the same person.
	var matchThreshold: Float { get }
	func embed(_ sample: FaceSample) -> Faceprint?
	/// The same face described by its upper half alone, for matching under a mask.
	func embedUpperFace(_ sample: FaceSample) -> Faceprint?
	/// How alike two prints are, 0...1.
	///
	/// Part of the embedder rather than of `Faceprint` because the right metric depends
	/// entirely on what the numbers mean. Learned embeddings are trained so that angle
	/// carries identity, and cosine is correct for them. Raw coordinates are not: see
	/// `LandmarkEmbedder`.
	func similarity(_ a: Faceprint, _ b: Faceprint) -> Float
	/// Runs one throwaway prediction so the first real frame doesn't pay for loading the model.
	func warmUp()
}

extension FaceEmbedder {
	package func warmUp() {}
	/// Nil where the embedder cannot describe the upper face alone (the geometry
	/// fallback): the mask path then never matches, rather than failing.
	package func embedUpperFace(_ sample: FaceSample) -> Faceprint? { nil }
}

extension FaceEmbedder {
	package var usesCosineSimilarity: Bool { false }
	package func similarity(_ a: Faceprint, _ b: Faceprint) -> Float { a.similarity(to: b) }
}

// MARK: - Selection

package enum Embedders {
	/// The Core ML embedder when a model is bundled, otherwise the geometry fallback.
	///
	/// Local weights at `Resources/FaceEmbedding.mlpackage` are compiled by build.sh.
	/// Their distribution rights are tracked separately in NOTICE.md; a source-code
	/// license does not establish the license of a weight file. The geometry fallback
	/// remains available for practice, but UnlockGuard refuses it for Mac unlocking.
	// The signed app bundle is immutable for the lifetime of this process. Reuse the
	// model for enrollment, scans and readiness checks; a new build needs a relaunch.
	private static let selected: any FaceEmbedder = CoreMLEmbedder() ?? LandmarkEmbedder()

	package static func best() -> any FaceEmbedder {
		selected
	}
}

// MARK: - Landmark geometry (no model required)

/// Describes a face by the *shape* of its landmarks, in a pose-normalised frame.
///
/// This is the honest floor of what is achievable with zero model weights. It encodes
/// bone geometry — eye spacing, nose width, jaw outline — which is stable, but it
/// throws away skin, texture and colour, which is most of what separates two people
/// with similar face shapes. Expect it to distinguish you from a stranger and to
/// struggle with siblings. Treat it as convenience-grade until a model is dropped in.
package struct LandmarkEmbedder: FaceEmbedder {
	package let identifier = "landmark-geometry-v2"
	package let matchThreshold: Float = 0.55

	package init() {}

	/// Distance between corresponding landmarks, not the angle between the vectors.
	///
	/// Cosine similarity was measurably wrong here — it scored a completely different
	/// person at 1.000. After normalisation every face has its eyes, nose and mouth in
	/// nearly the same canonical positions, so the vectors are dominated by that shared
	/// template and come out parallel no matter whose face it is. Identity lives in the
	/// small residual displacement, which is exactly what an angle discards.
	///
	/// So: root-mean-square displacement, in interocular widths, mapped to 0...1. Same
	/// person lands around 0.02–0.04 RMS; different people are several times that.
	package func similarity(_ a: Faceprint, _ b: Faceprint) -> Float {
		guard !a.source.isEmpty, a.source == b.source, a.values.count == b.values.count,
			!a.values.isEmpty, a.values.count.isMultiple(of: 2)
		else { return 0 }

		var sumSquares: Float = 0
		vDSP_distancesq(a.values, 1, b.values, 1, &sumSquares, vDSP_Length(a.values.count))
		guard sumSquares.isFinite else { return 0 }
		// Two coordinates per landmark, so halve the count to get per-point displacement.
		let rms = sqrt(sumSquares / Float(a.values.count / 2))

		// 0.12 interocular widths of average displacement is treated as "unrelated".
		// Tuned against real measurements from the Test Recognition screen rather than
		// guessed — check both a matching and a non-matching face after changing it.
		return max(0, 1 - rms / 0.12)
	}

	package func embed(_ sample: FaceSample) -> Faceprint? {
		let lm = sample.landmarks

		// Anchor on the pupils. Everything is expressed relative to them, which cancels
		// out distance from the camera, head tilt and where the face sits in frame.
		guard
			let leftPupil = lm.leftPupil?.normalizedPoints.first,
			let rightPupil = lm.rightPupil?.normalizedPoints.first
		else { return nil }

		let origin = CGPoint(
			x: (leftPupil.x + rightPupil.x) / 2,
			y: (leftPupil.y + rightPupil.y) / 2)
		let axis = CGVector(dx: rightPupil.x - leftPupil.x, dy: rightPupil.y - leftPupil.y)
		let interocular = hypot(axis.dx, axis.dy)
		guard interocular > 0.01 else { return nil }

		// Rotate so the eye line is horizontal, scale so the eyes are one unit apart.
		let cosT = axis.dx / interocular
		let sinT = axis.dy / interocular

		func canonical(_ p: CGPoint) -> (Float, Float) {
			let dx = (p.x - origin.x) / interocular
			let dy = (p.y - origin.y) / interocular
			return (Float(dx * cosT + dy * sinT), Float(-dx * sinT + dy * cosT))
		}

		// Ordered so the same index always means the same facial position.
		let regions: [VNFaceLandmarkRegion2D?] = [
			lm.faceContour, lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow,
			lm.nose, lm.noseCrest, lm.medianLine, lm.outerLips, lm.innerLips,
		]

		var values: [Float] = []
		values.reserveCapacity(160)
		for region in regions {
			guard let region else { return nil }
			for point in region.normalizedPoints {
				let (x, y) = canonical(point)
				values.append(x)
				values.append(y)
			}
		}

		guard values.count >= 40 else { return nil }
		return Faceprint(values: values, source: identifier)
	}
}

// MARK: - Core ML

/// Wraps the bundled embedding model: one square NCHW RGB tensor input and one
/// multi-array output. Models with a different preprocessing contract are rejected.
///
/// Copies share a `PredictionBox` whose `Synchronization.Mutex` owns the reuse scratch
/// buffers and serializes tensor filling and Core ML predictions; each caller owns its crop.
package struct CoreMLEmbedder: FaceEmbedder, Sendable {
	package let identifier: String
	package let usesCosineSimilarity = true
	/// Historical operating point, not a calibrated false-accept guarantee. Repeated
	/// webcam frames are correlated; holding a match cannot make a weak threshold safe.
	/// Template agreement and movement checks supplement this threshold. Population
	/// and low-light validation are still required with the actual bundled weights.
	package let matchThreshold: Float = 0.45

	/// `@unchecked Sendable` for non-Sendable `MLModel`; Core ML predictions are synchronized
	/// by `PredictionBox.mutex` (or isolated warm-up tensors) via `ModelSlot`.
	private struct ValidatedModel: @unchecked Sendable {
		let model: MLModel
		let inputName: String
		let outputName: String
	}

	private let slot: ModelSlot<ValidatedModel>
	/// Copies of the embedder share one mutex-protected scratch buffer; every fill and
	/// Core ML prediction executes inside `predictionBox.mutex`.
	private let predictionBox: PredictionBox
	private let side: Int

	/// Expected side length of the bundled planar [1, 3, S, S] embedding model, validated
	/// against the loaded `MLModel`'s actual description on first off-main load.
	package static let expectedSide = 112

	/// Bump whenever the bundled model file changes. It becomes part of the print's
	/// `source`, and prints with different sources never compare (similarity returns 0).
	/// So swapping models can't silently mis-match faceprints from the old embedding
	/// space against the new one — it invalidates old enrolments and forces a re-enrol.
	package static let modelTag = "arcface-2.73"

	package init?() {
		guard let url = Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc") else { return nil }
		self.init(modelURL: url)
	}

	/// Defers `MLModel(contentsOf:)` out of synchronous init so MainActor launch never
	/// stalls compiling weights; schema/shape is validated on first load and fails closed.
	package init?(modelURL: URL, expectedSide: Int = Self.expectedSide) {
		guard (16...1024).contains(expectedSide),
			FileManager.default.fileExists(atPath: modelURL.path),
			let scratch = TensorScratch(side: expectedSide)
		else { return nil }
		self.slot = ModelSlot<ValidatedModel> {
			Self.loadValidatedModel(at: modelURL, expectedSide: expectedSide)
		}
		self.side = expectedSide
		self.predictionBox = PredictionBox(scratch: scratch)
		// Version the identifier so swapping models invalidates old enrolments rather
		// than silently comparing prints from different feature spaces.
		self.identifier = "coreml:\(expectedSide)x\(expectedSide):\(Self.modelTag)"
	}

	private static func loadValidatedModel(at url: URL, expectedSide: Int) -> ValidatedModel? {
		guard let model = try? MLModel(contentsOf: url) else { return nil }
		// Models in this family take a planar [1, 3, S, S] tensor rather than an image
		// feature, so validate the input/output contract before trusting predictions.
		let inputs = model.modelDescription.inputDescriptionsByName
		let outputs = model.modelDescription.outputDescriptionsByName
		guard
			inputs.count == 1, let input = inputs.values.first,
			let constraint = input.multiArrayConstraint,
			constraint.shape.count == 4,
			constraint.shape[0].intValue == 1, constraint.shape[1].intValue == 3,
			constraint.shape[2] == constraint.shape[3],
			constraint.shape[3].intValue == expectedSide,
			(16...1024).contains(constraint.shape[3].intValue),
			outputs.count == 1, let output = outputs.values.first,
			output.multiArrayConstraint != nil
		else { return nil }
		return ValidatedModel(model: model, inputName: input.name, outputName: output.name)
	}

	package func warmUp() {
		slot.warmUpOnce { loaded in
			guard let tensor = try? MLMultiArray(
					shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32),
				let input = try? MLDictionaryFeatureProvider(
					dictionary: [loaded.inputName: MLFeatureValue(multiArray: tensor)])
			else { return false }
			return (try? loaded.model.prediction(from: input)) != nil
		}
	}

	package func embed(_ sample: FaceSample) -> Faceprint? {
		guard let crop = FaceAligner.alignedCrop(sample, side: side) else { return nil }
		return predict(crop)
	}

	/// The upper face with the lower 45% masked to neutral grey, run through the
	/// same model — the half a mask leaves visible, in the same feature space so
	/// it compares against prints captured the same way at enrolment.
	package func embedUpperFace(_ sample: FaceSample) -> Faceprint? {
		guard let crop = FaceAligner.alignedCrop(sample, side: side) else { return nil }
		guard CVPixelBufferLockBaseAddress(crop, []) == kCVReturnSuccess else { return nil }
		defer { CVPixelBufferUnlockBaseAddress(crop, []) }
		guard let base = CVPixelBufferGetBaseAddress(crop) else { return nil }
		let rowBytes = CVPixelBufferGetBytesPerRow(crop)
		let pixels = base.assumingMemoryBound(to: UInt8.self)
		let maskedFrom = Int(Double(side) * 0.55)
		// Neutral grey, not black: the model reads it as no information rather
		// than as a shadowed face.
		for y in maskedFrom..<side {
			let row = pixels + y * rowBytes
			for x in 0..<side {
				let px = row + x * 4
				px[0] = 128
				px[1] = 128
				px[2] = 128
				px[3] = 255
			}
		}
		return predict(crop)
	}

	/// One prediction on an aligned crop: tensor in, L2-normalised print out.
	///
	/// Fill and prediction share `predictionBox.mutex` because the scratch tensor is reused
	/// across frames: filling outside the lock would race the next frame's fill.
	private func predict(_ crop: CVPixelBuffer) -> Faceprint? {
		// Local reference: the slot lock is released before predicting, so an
		// unload sweep never waits on a frame (and vice versa beyond a load).
		guard let loaded = slot.withModel({ $0 }) else { return nil }
		let values: [Float]? = predictionBox.mutex.withLock { scratch in
			guard let tensor = self.fillTensor(from: crop, into: scratch),
				let input = try? MLDictionaryFeatureProvider(
					dictionary: [loaded.inputName: MLFeatureValue(multiArray: tensor)]),
				let output = try? loaded.model.prediction(from: input),
				let array = output.featureValue(for: loaded.outputName)?.multiArrayValue,
				(1...4096).contains(array.count)
			else { return nil }
			return Self.extractFloats(from: array)
		}
		guard let values else { return nil }
		// L2-normalise. These embeddings are trained so identity lives in direction, not
		// magnitude, so normalising makes cosine similarity a plain dot product and keeps
		// scores comparable across lighting.
		return Faceprint.normalized(values, source: identifier)
	}

	/// Extracts `MLMultiArray` elements into `[Float]` via contiguous `.float32`/`.float16`
	/// buffer reads when row-major contiguous, falling back to subscript indexing for
	/// non-contiguous strides or other element types.
	package static func extractFloats(from array: MLMultiArray) -> [Float] {
		let count = array.count
		guard count > 0 else { return [] }
		if isContiguousRowMajor(array) {
			switch array.dataType {
			case .float32:
				var extracted = [Float](repeating: 0, count: count)
				let ok = array.withUnsafeBytes { raw -> Bool in
					let byteCount = count * MemoryLayout<Float>.stride
					guard let src = raw.baseAddress, raw.count >= byteCount else { return false }
					extracted.withUnsafeMutableBytes { dst in
						dst.copyMemory(from: UnsafeRawBufferPointer(start: src, count: byteCount))
					}
					return true
				}
				if ok { return extracted }
			case .float16:
				var extracted = [Float](repeating: 0, count: count)
				let ok = array.withUnsafeBytes { raw -> Bool in
					let byteCount = count * 2
					guard let src = raw.baseAddress, raw.count >= byteCount else { return false }
					return extracted.withUnsafeMutableBytes { dst -> Bool in
						guard let dstBase = dst.baseAddress else { return false }
						var srcBuf = vImage_Buffer(
							data: UnsafeMutableRawPointer(mutating: src),
							height: 1,
							width: vImagePixelCount(count),
							rowBytes: count * 2)
						var dstBuf = vImage_Buffer(
							data: dstBase,
							height: 1,
							width: vImagePixelCount(count),
							rowBytes: count * MemoryLayout<Float>.stride)
						return vImageConvert_Planar16FtoPlanarF(
							&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags)
						) == kvImageNoError
					}
				}
				if ok { return extracted }
			default:
				break
			}
		}
		var extracted = [Float](repeating: 0, count: count)
		for i in 0..<count {
			extracted[i] = array[i].floatValue
		}
		return extracted
	}

	private static func isContiguousRowMajor(_ array: MLMultiArray) -> Bool {
		let shape = array.shape
		let strides = array.strides
		guard shape.count == strides.count, !shape.isEmpty else { return false }
		var expected = 1
		for i in shape.indices.reversed() {
			let dim = shape[i].intValue
			guard dim > 0, strides[i].intValue == expected else { return false }
			expected *= dim
		}
		return true
	}

	/// Converts a BGRA crop into the planar RGB tensor the model expects, reusing the
	/// per-instance scratch tensor instead of allocating one per frame.
	///
	/// Two conversions matter and both are easy to get subtly wrong: the buffer is BGRA
	/// and interleaved, while the model wants RGB in separate channel planes; and pixels
	/// must be scaled to [-1, 1] rather than [0, 1], which is the convention this model
	/// family is trained with. Getting either wrong yields embeddings that look valid but
	/// match nobody.
	///
	/// Original per-pixel math, preserved exactly (planar RGB, NCHW [1, 3, S, S]):
	///   plane 0[i] = (r - 127.5) / 128.0
	///   plane 1[i] = (g - 127.5) / 128.0
	///   plane 2[i] = (b - 127.5) / 128.0
	/// where r, g, b are the crop bytes at offsets 2, 1, 0 of each BGRA pixel.
	/// The vector path computes `Float(byte) * (1/128) + (-127.5/128)` instead. 1/128
	/// and 127.5/128 are exactly representable in binary32, the byte-to-float conversion
	/// is exact, and scaling by a power of two is exact, so this performs the same single
	/// rounding of the same real value as `(c - 127.5) / 128.0` — bit-identical output.
	private func fillTensor(from buffer: CVPixelBuffer, into scratch: TensorScratch) -> MLMultiArray? {
		guard
			CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
			CVPixelBufferGetWidth(buffer) == side, CVPixelBufferGetHeight(buffer) == side,
			CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
		else { return nil }
		defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

		guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
		var src = vImage_Buffer(
			data: base, height: vImagePixelCount(side), width: vImagePixelCount(side),
			rowBytes: CVPixelBufferGetBytesPerRow(buffer))

		// Split the interleaved bytes into planar R, G, B. vImage channel indices are
		// positional: byte 0 = B, byte 1 = G, byte 2 = R, byte 3 = A.
		let plane = scratch.plane
		var ok = true
		for (planeIndex, channel) in [(0, 2), (1, 1), (2, 0)] {
			var dest = vImage_Buffer(
				data: scratch.planar + planeIndex * plane,
				height: vImagePixelCount(side), width: vImagePixelCount(side),
				rowBytes: side)
			if vImageExtractChannel_ARGB8888(&src, &dest, channel, vImage_Flags(kvImageNoFlags))
				!= kvImageNoError
			{
				ok = false
			}
		}
		guard ok else { return nil }

		// Bytes to [-1, 1] floats, one plane at a time, straight into the tensor.
		let out = scratch.tensor.dataPointer.assumingMemoryBound(to: Float.self)
		var scale = Float(1.0 / 128.0)
		var shift = Float(-127.5 / 128.0)
		for planeIndex in 0..<3 {
			let bytes = scratch.planar + planeIndex * plane
			let floats = out + planeIndex * plane
			vDSP_vfltu8(bytes, 1, floats, 1, vDSP_Length(plane))
			vDSP_vsmsa(floats, 1, &scale, &shift, floats, 1, vDSP_Length(plane))
		}

		return scratch.tensor
	}

	/// Reference-counted holder for the non-copyable `Synchronization.Mutex` so value copies
	/// of `CoreMLEmbedder` share the same prediction lock and reuse buffers.
	private final class PredictionBox: Sendable {
		let mutex: Mutex<TensorScratch>

		init(scratch: TensorScratch) {
			self.mutex = Mutex(scratch)
		}
	}

	/// Per-instance reuse buffers: one output tensor plus three planar byte planes,
	/// all sized by `side` at init. `@unchecked Sendable` for `MLMultiArray` and the raw
	/// planar `UnsafeMutablePointer<UInt8>`; every access occurs strictly inside `PredictionBox.mutex`.
	private final class TensorScratch: @unchecked Sendable {
		let tensor: MLMultiArray
		let planar: UnsafeMutablePointer<UInt8>
		let plane: Int

		init?(side: Int) {
			let plane = side * side
			guard plane > 0,
				let tensor = try? MLMultiArray(
					shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
			else { return nil }
			self.tensor = tensor
			self.planar = UnsafeMutablePointer<UInt8>.allocate(capacity: 3 * plane)
			self.plane = plane
		}

		deinit { planar.deallocate() }
	}
}
