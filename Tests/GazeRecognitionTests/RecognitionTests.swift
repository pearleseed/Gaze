import CoreGraphics
import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import GazeRecognition
import Synchronization
import Testing
import Vision

private final class MutableStubEmbedder: FaceEmbedder {
	let identifier = "coreml:test"
	let usesCosineSimilarity = true
	let matchThreshold: Float = 0.45
	private let currentPrint = Mutex<Faceprint?>(nil)

	init(print: Faceprint? = nil) {
		currentPrint.withLock { $0 = print }
	}

	func setPrint(_ print: Faceprint?) {
		currentPrint.withLock { $0 = print }
	}

	func embed(_ sample: FaceSample) -> Faceprint? {
		currentPrint.withLock { $0 }
	}
}

@Suite("Recognition Matching, Evaluator & Aligner")
struct RecognitionTests {
	private func printAt(_ cosine: Float, source: String = "coreml:test") -> Faceprint {
		Faceprint(values: [cosine, sqrt(max(0, 1 - cosine * cosine))], source: source)
	}

	private func rejects(_ matcher: FaceTemplateMatcher, _ candidate: Faceprint) -> Bool {
		do {
			_ = try matcher.bestMatch(to: candidate)
			return false
		} catch {
			return true
		}
	}

	private func makeBuffer(width: Int = 640, height: Int = 480) throws -> CVPixelBuffer {
		var result: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &result
		)
		#expect(status == kCVReturnSuccess)
		return try #require(result)
	}

	private func makeSample(
		pixelBuffer: CVPixelBuffer,
		boundingBox: CGRect = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6),
		pose: FacePose = .zero,
		quality: Float = 0.8,
		hasQualityMeasurement: Bool = true
	) throws -> FaceSample {
		let face = VNFaceObservation(boundingBox: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6))
		let request = VNDetectFaceLandmarksRequest()
		request.inputFaceObservations = [face]
		try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
		let landmarks = try #require(request.results?.first?.landmarks)
		return FaceSample(
			landmarks: landmarks,
			boundingBox: boundingBox,
			pose: pose,
			quality: quality,
			hasQualityMeasurement: hasQualityMeasurement,
			pixelBuffer: pixelBuffer
		)
	}

	@Test func templateMatchingSupportValidationAndAcceleratedCosine() throws {
		let embedder = MutableStubEmbedder()
		let candidate = printAt(1)
		func index(_ prints: [[Faceprint]]) -> FaceTemplateMatcher {
			FaceTemplateMatcher(templates: prints, embedder: embedder)
		}

		#expect(Faceprint.normalized([0, 0], source: "test") == nil)
		#expect(Faceprint.normalized([.nan, 1], source: "test") == nil)
		#expect(Faceprint.normalized([.infinity, 1], source: "test") == nil)
		#expect(Faceprint.normalized([1], source: "") == nil)

		let singleton = try #require(try index([[candidate]]).bestMatch(to: candidate))
		#expect(singleton.score == 1)

		let isolated = try #require(try index([[candidate, printAt(0.2), printAt(0.1)]]).bestMatch(to: candidate))
		#expect(abs(isolated.score - 0.2) < 0.00001)

		let supported = try #require(try index([[printAt(0.9), printAt(0.8), printAt(0.1)]]).bestMatch(to: candidate))
		#expect(abs(supported.score - 0.8) < 0.00001)

		let separate = try #require(try index([[candidate, printAt(0.1)], [candidate, printAt(0.2)]]).bestMatch(to: candidate))
		#expect(separate.score < embedder.matchThreshold)

		let selected = try #require(try index([[candidate, printAt(0.1)], [printAt(0.8), printAt(0.7)]]).bestMatch(to: candidate))
		#expect(selected.index == 1)

		#expect(rejects(index([[candidate]]), printAt(1, source: "wrong")))
		#expect(rejects(index([[printAt(1, source: "wrong")]]), candidate))
		#expect(rejects(index([[Faceprint(values: [1, .nan], source: embedder.identifier)]]), candidate))
		#expect(rejects(index([[Faceprint(values: [1], source: embedder.identifier)]]), candidate))
		#expect(rejects(index([[]]), candidate))
		#expect(rejects(index([[candidate]]), Faceprint(values: [0, 0], source: embedder.identifier)))

		// Accelerated cosine agrees with the scalar reference across non-normalized inputs.
		for seed in 1...100 {
			let vectors = (0..<8).map { row in
				Faceprint(
					values: (0..<128).map { column in
						Float(sin(Double(seed * 131 + row * 17 + column)))
					},
					source: embedder.identifier
				)
			}
			let query = vectors[seed % vectors.count]
			let expected = vectors.map { $0.similarity(to: query) }.sorted(by: >)[1]
			let actual = try #require(try index([vectors]).bestMatch(to: query)).score
			#expect(abs(actual - max(0, expected)) < 0.00001)
		}

		let geometry = LandmarkEmbedder()
		let geometryPrint = Faceprint(values: [0.1, 0.2, 0.4, 0.6], source: geometry.identifier)
		let geometryMatch = try #require(
			try FaceTemplateMatcher(templates: [[geometryPrint]], embedder: geometry).bestMatch(to: geometryPrint)
		)
		#expect(geometryMatch.score == 1)
		let shifted = Faceprint(values: [0.13, 0.2, 0.43, 0.6], source: geometry.identifier)
		#expect(abs(geometry.similarity(geometryPrint, shifted) - 0.75) < 0.00001)
		let invalidGeometry = Faceprint(values: [.nan, 0.2, 0.4, 0.6], source: geometry.identifier)
		#expect(geometry.similarity(geometryPrint, invalidGeometry) == 0)
	}

	@Test func frameQualityEvaluatorEnrollmentAndContextCrop() async throws {
		let candidate = printAt(1)
		let embedder = MutableStubEmbedder(print: candidate)
		let buffer = try makeBuffer()
		let baseSample = try makeSample(pixelBuffer: buffer)

		#expect(FrameQuality.isUsable(baseSample))
		#expect(FrameQuality.rejection(try makeSample(pixelBuffer: buffer, quality: 0, hasQualityMeasurement: true)) == .tooBlurred)
		#expect(FrameQuality.isUsable(try makeSample(pixelBuffer: buffer, quality: 0, hasQualityMeasurement: false)))
		#expect(FrameQuality.rejection(try makeSample(pixelBuffer: buffer, quality: .nan, hasQualityMeasurement: true)) == .invalidMeasurements)

		let face = FaceEnrollment(
			name: "Owner",
			prints: [candidate, printAt(0.8)],
			embedder: embedder.identifier,
			cameraID: "cam"
		)
		let evaluator = UnlockFrameEvaluator(embedder: embedder, faces: [face], antiSpoof: nil)
		let good = await evaluator.evaluate(baseSample)
		#expect(good.matched && good.permitsMatchHold(requiresAntiSpoof: false))
		#expect(!good.permitsMatchHold(requiresAntiSpoof: true))

		let zeroQualitySample = try makeSample(pixelBuffer: buffer, quality: 0, hasQualityMeasurement: true)
		let bad = await evaluator.evaluate(zeroQualitySample)
		#expect(bad.failure == .unusableFrame && !bad.comparedIdentity)

		let nanPoseSample = try makeSample(pixelBuffer: buffer, pose: FacePose(yaw: .nan, pitch: 0, roll: 0))
		let turnedSample = try makeSample(pixelBuffer: buffer, pose: FacePose(yaw: 0.2, pitch: 0, roll: 0))
		await MainActor.run {
			let enrollment = EnrollmentModel(embedder: embedder)
			enrollment.consume(nanPoseSample)
			#expect(enrollment.captureStatus == .invalidMeasurements)
			for _ in 0..<9 { enrollment.consume(baseSample) }
			#expect(enrollment.prints.count == 1)

			embedder.setPrint(printAt(0.1))
			enrollment.consume(turnedSample)
			#expect(enrollment.prints.count == 1 && enrollment.progress == 0)
			#expect(enrollment.captureStatus == .inconsistentFace)

			embedder.setPrint(printAt(0.8))
			enrollment.consume(turnedSample)
			#expect(enrollment.prints.count == 2 && enrollment.progress > 0)
		}

		// A crop larger than the source's short side must still fill every output row.
		CVPixelBufferLockBaseAddress(buffer, [])
		memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetDataSize(buffer))
		CVPixelBufferUnlockBaseAddress(buffer, [])

		let wideBoxSample = try makeSample(
			pixelBuffer: buffer,
			boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
		)
		let crop = try #require(FaceAligner.contextCrop(wideBoxSample, side: 80))
		CVPixelBufferLockBaseAddress(crop, .readOnly)
		let pixels = try #require(CVPixelBufferGetBaseAddress(crop)).assumingMemoryBound(to: UInt8.self)
		let stride = CVPixelBufferGetBytesPerRow(crop)
		#expect((0..<80).allSatisfy { pixels[$0 * stride + 40 * 4 + 3] > 250 })
		CVPixelBufferUnlockBaseAddress(crop, .readOnly)
		#expect(FaceAligner.contextCrop(wideBoxSample, side: 80, margin: .nan) == nil)
	}

	@Test func settlingExposureFailsClosedWithoutLockingOutOnColdCameraFrames() async throws {
		let candidate = printAt(1)
		let embedder = MutableStubEmbedder(print: candidate)
		let buffer = try makeBuffer()
		let sample = try makeSample(pixelBuffer: buffer)
		let face = FaceEnrollment(
			name: "Owner",
			prints: [candidate, printAt(0.8)],
			embedder: embedder.identifier,
			cameraID: "cam"
		)

		let spoofScore = Mutex<Float>(0.99)
		let gate = AntiSpoofGate(confidence: { _, _ in spoofScore.withLock { $0 } })
		let evaluator = UnlockFrameEvaluator(embedder: embedder, faces: [face], antiSpoof: gate)

		// Cold-camera exposure settle: spoof spikes fail closed as `.suspect` (never permitting match hold)
		// without accumulating into a lockout-triggering `.spoof` rejection.
		for _ in 0..<(UnlockFrameEvaluator.classifierFireFrames + 2) {
			let result = await evaluator.evaluate(sample, settlingExposure: true)
			#expect(result.matched)
			#expect(!result.permitsMatchHold(requiresAntiSpoof: true))
			#expect(!result.permitsMatchHold(requiresAntiSpoof: false))
			guard case .suspect = result.spoofDecision else {
				Issue.record("Expected .suspect during exposure settle, got \(String(describing: result.spoofDecision))")
				return
			}
		}

		// Once exposure has settled, the classifier starts from a clean count and still fires at classifierFireFrames.
		for index in 1...UnlockFrameEvaluator.classifierFireFrames {
			let result = await evaluator.evaluate(sample, settlingExposure: false)
			#expect(!result.permitsMatchHold(requiresAntiSpoof: true))
			if index < UnlockFrameEvaluator.classifierFireFrames {
				guard case .suspect = result.spoofDecision else {
					Issue.record("Expected .suspect before classifierFireFrames, got \(String(describing: result.spoofDecision))")
					return
				}
			} else {
				guard case .spoof = result.spoofDecision else {
					Issue.record("Expected .spoof at classifierFireFrames, got \(String(describing: result.spoofDecision))")
					return
				}
			}
		}

		// Genuine live frames during exposure settle still pass immediately without delay.
		await evaluator.resetSpoofCues()
		spoofScore.withLock { $0 = 0.05 }
		let liveDuringSettle = await evaluator.evaluate(sample, settlingExposure: true)
		#expect(liveDuringSettle.spoofDecision == .live)
		#expect(liveDuringSettle.permitsMatchHold(requiresAntiSpoof: true))
	}
}
