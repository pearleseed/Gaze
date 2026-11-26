import CoreImage
import CoreML
import CoreVideo
import Foundation
import GazeCamera
import Synchronization
import Vision

/// Finds the pupil with Google's MediaPipe Iris model (Apache 2.0, see
/// ThirdParty/MediaPipeIris). A 64x64 crop around each eye goes in; the iris centre
/// and the eye's own corners come out, so the pupil's place inside the eye is measured
/// by one model rather than two rough estimates.
package enum IrisLocator {

	private static let side = 64
	/// The crop is wider than the eye, as MediaPipe crops it: the eye is about half of it.
	private static let cropScale: CGFloat = 2.0

	private static let slot = ModelSlot<MLModel> {
		guard let url = Bundle.main.url(forResource: "IrisLandmarks", withExtension: "mlmodelc") else { return nil }
		return try? MLModel(contentsOf: url)
	}

	/// `@unchecked Sendable` for Core Image / Core Video C handles (`CIContext`, `CVPixelBuffer`);
	/// all reads and writes are strictly serialized by `state`.
	private struct State: @unchecked Sendable {
		let context = CIContext(options: [.cacheIntermediates: false])
		var warming = false
		/// The last frame's answer, so the same frame read twice runs the model once.
		var lastBuffer: CVPixelBuffer?
		var lastResult: Gaze?
		var scratch: CVPixelBuffer?
	}

	private static let state = Mutex(State())

	/// Where the pupils sit inside the eyes, averaged over both eyes and scaled by eye
	/// width. x is positive toward image +x (the person's own left), the same polarity
	/// as `LivenessChallenge.gazeOffset`; y is positive looking up.
	package struct Gaze: Sendable {
		package var x: Double
		package var y: Double

		package init(x: Double, y: Double) {
			self.x = x
			self.y = y
		}
	}

	/// Loads the model and compiles it for the Neural Engine off the main thread.
	/// That first load takes seconds; doing it on a camera frame froze the window.
	package static func warmUp() {
		let start = state.withLock { state -> Bool in
			guard !state.warming else { return false }
			state.warming = true
			return true
		}
		guard start else { return }
		Task.detached(priority: .userInitiated) {
			_ = slot.warmUpOnce { model in
				var buffer: CVPixelBuffer?
				guard CVPixelBufferCreate(
					kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
					[kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
				) == kCVReturnSuccess,
					let buffer,
					let input = try? MLDictionaryFeatureProvider(dictionary: ["eye": MLFeatureValue(pixelBuffer: buffer)])
				else { return false }
				return (try? model.prediction(from: input)) != nil
			}
			state.withLock { $0.warming = false }
		}
	}

	/// Mean horizontal pupil offset over both eyes, as (iris.x - eyeCentre.x) / eyeWidth.
	/// Positive is toward image +x, the same polarity as `LivenessChallenge.gazeOffset`.
	/// Nil when the model is missing or no eye could be read.
	package static func horizontalOffset(_ sample: FaceSample) -> Double? { gaze(sample)?.x }

	/// Drops the remembered camera frame. Holding it kept the camera's buffer pool
	/// alive between locks, about 19 MB doing nothing.
	package static func forgetFrame() {
		state.withLock { state in
			state.lastBuffer = nil
			state.lastResult = nil
		}
	}

	package static func gaze(_ sample: FaceSample) -> Gaze? {
		let buffer = sample.pixelBuffer
		if let cached = state.withLock({ $0.lastBuffer === buffer ? Optional($0.lastResult) : nil }) { return cached }
		let result = measure(sample)
		state.withLock { state in
			state.lastBuffer = buffer
			state.lastResult = result
		}
		return result
	}

	private static func measure(_ sample: FaceSample) -> Gaze? {
		// Never load here: this runs per camera frame, often on the main thread.
		guard slot.ifLoaded({ _ in true }) == true else {
			warmUp()
			return nil
		}
		let buffer = sample.pixelBuffer
		let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
		guard size.width > 0, size.height > 0 else { return nil }
		// MediaPipe runs one eye as-is and the other mirrored, the way the model was trained.
		let eyes = [(sample.landmarks.leftEye?.normalizedPoints, false), (sample.landmarks.rightEye?.normalizedPoints, true)]
		let offsets = eyes.compactMap { outline, mirrored -> Gaze? in
			guard let outline, outline.count >= 3 else { return nil }
			// Vision image coordinates: origin bottom-left, like Core Image's.
			let points = outline.map { p in
				CGPoint(x: (sample.boundingBox.minX + p.x * sample.boundingBox.width) * size.width,
					y: (sample.boundingBox.minY + p.y * sample.boundingBox.height) * size.height)
			}
			return offset(eye: points, in: buffer, mirrored: mirrored)
		}
		guard !offsets.isEmpty else { return nil }
		let n = Double(offsets.count)
		return Gaze(x: offsets.map(\.x).reduce(0, +) / n, y: offsets.map(\.y).reduce(0, +) / n)
	}

	private static func offset(eye points: [CGPoint], in buffer: CVPixelBuffer, mirrored: Bool) -> Gaze? {
		let xs = points.map(\.x), ys = points.map(\.y)
		guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
			maxX - minX >= 6 else { return nil }
		let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
		// Sized by eye width, not height, so narrow eyes still get a full-size crop.
		let span = (maxX - minX) * cropScale
		let crop = CGRect(x: centre.x - span / 2, y: centre.y - span / 2, width: span, height: span)

		return state.withLock { state -> Gaze? in
			guard let target = scratchBuffer(in: &state) else { return nil }
			let scale = CGFloat(side) / span
			var image = CIImage(cvPixelBuffer: buffer)
				.cropped(to: crop)
				.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
				.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
			if mirrored {
				image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -CGFloat(side), y: 0))
			}
			state.context.render(image, to: target)
			guard let output = slot.ifLoaded({ model in
				try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["eye": MLFeatureValue(pixelBuffer: target)]))
			}) ?? nil,
				let iris = output.featureValue(for: "iris")?.multiArrayValue,
				let contour = output.featureValue(for: "contour")?.multiArrayValue,
				iris.count >= 15, contour.count >= 16 * 3 else { return nil }
			// Contour points 0...15 are the lid outline; its extremes are the eye corners,
			// its mean height the eye's middle.
			var cornerMin = Double.greatestFiniteMagnitude, cornerMax = -Double.greatestFiniteMagnitude
			var lidY = 0.0
			for index in 0..<16 {
				let x = contour[index * 3].doubleValue
				cornerMin = min(cornerMin, x); cornerMax = max(cornerMax, x)
				lidY += contour[index * 3 + 1].doubleValue / 16
			}
			let width = cornerMax - cornerMin
			guard width > 4, iris.count >= 15 else { return nil }
			// The centre point averaged with the middle of the four edge points: steadier
			// than either alone.
			var edgeX = 0.0, edgeY = 0.0
			for index in 1...4 { edgeX += iris[index * 3].doubleValue / 4; edgeY += iris[index * 3 + 1].doubleValue / 4 }
			let irisX = (iris[0].doubleValue + edgeX) / 2
			let irisY = (iris[1].doubleValue + edgeY) / 2
			// The crop is rendered upright, so the model's y runs down the eye: up is negative.
			let gaze = Gaze(x: (irisX - (cornerMin + cornerMax) / 2) / width * (mirrored ? -1 : 1),
				y: -(irisY - lidY) / width)
			return gaze.x.isFinite && gaze.y.isFinite ? gaze : nil
		}
	}

	private static func scratchBuffer(in state: inout State) -> CVPixelBuffer? {
		if let scratch = state.scratch { return scratch }
		var buffer: CVPixelBuffer?
		CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
			[kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
		state.scratch = buffer
		return buffer
	}
}
