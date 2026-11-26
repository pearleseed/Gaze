import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import GazeRecognition
import Synchronization
import Testing
import Vision

private struct StubEmbedder: FaceEmbedder {
	let identifier = "coreml:test"
	let usesCosineSimilarity = true
	let matchThreshold: Float = 0.45
	let printToReturn: Faceprint?

	func embed(_ sample: FaceSample) -> Faceprint? {
		printToReturn
	}
}

private func makePixelBuffer(width: Int, height: Int, fillByte: UInt8 = 128) throws -> CVPixelBuffer {
	var pixelBuffer: CVPixelBuffer?
	let status = CVPixelBufferCreate(
		kCFAllocatorDefault,
		width,
		height,
		kCVPixelFormatType_32BGRA,
		nil,
		&pixelBuffer
	)
	#expect(status == kCVReturnSuccess)
	let buffer = try #require(pixelBuffer)
	#expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
	defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
	if let base = CVPixelBufferGetBaseAddress(buffer) {
		memset(base, Int32(fillByte), CVPixelBufferGetBytesPerRow(buffer) * height)
	}
	return buffer
}

private func makeStubLandmarks(pixelBuffer: CVPixelBuffer, boundingBox: CGRect) throws -> VNFaceLandmarks2D {
	let face = VNFaceObservation(boundingBox: boundingBox)
	let request = VNDetectFaceLandmarksRequest()
	request.inputFaceObservations = [face]
	try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
	return try #require(request.results?.first?.landmarks)
}

private func naiveScalarCosine(_ a: [Float], _ b: [Float]) -> Float {
	var dot: Float = 0
	var normA: Float = 0
	var normB: Float = 0
	for i in a.indices {
		dot += a[i] * b[i]
		normA += a[i] * a[i]
		normB += b[i] * b[i]
	}
	guard dot.isFinite, normA.isFinite, normB.isFinite, normA > 0, normB > 0 else { return 0 }
	let denom = sqrt(normA) * sqrt(normB)
	guard denom.isFinite, denom > 0 else { return 0 }
	let score = dot / denom
	return score.isFinite ? score : 0
}

private func withStridedMultiArray<T>(
	backing: inout [T],
	shape: [NSNumber],
	dataType: MLMultiArrayDataType,
	strides: [NSNumber],
	verify: (MLMultiArray) throws -> Void
) throws {
	try backing.withUnsafeMutableBytes { raw in
		let baseAddress = try #require(raw.baseAddress)
		let array = try MLMultiArray(
			dataPointer: baseAddress,
			shape: shape,
			dataType: dataType,
			strides: strides,
			deallocator: nil
		)
		try verify(array)
	}
}

@Suite("Recognition & Core ML Performance")
struct RecognitionPerformanceTests {

	@Test func warmUpOnceCoalescesTenConcurrentCallersAndRewarmsAfterIdleUnload() async {
		let loadCount = Mutex(0)
		let warmCount = Mutex(0)

		let slot = ModelSlot<String> {
			let n = loadCount.withLock { count -> Int in
				count += 1
				return count
			}
			Thread.sleep(forTimeInterval: 0.02)
			return "model-\(n)"
		}

		let outcomes = await withTaskGroup(of: Bool.self) { group in
			for _ in 0..<10 {
				group.addTask {
					slot.warmUpOnce { _ in
						warmCount.withLock { $0 += 1 }
						Thread.sleep(forTimeInterval: 0.02)
						return true
					}
				}
			}
			var results: [Bool] = []
			for await ok in group {
				results.append(ok)
			}
			return results
		}

		#expect(outcomes.count == 10)
		#expect(outcomes.allSatisfy { $0 })
		#expect(loadCount.withLock { $0 } == 1)
		#expect(warmCount.withLock { $0 } == 1)

		// Already warmed in the same residency cycle: second call must not re-run warm-up.
		let secondRun = slot.warmUpOnce { _ in
			warmCount.withLock { $0 += 1 }
			return true
		}
		#expect(secondRun)
		#expect(loadCount.withLock { $0 } == 1)
		#expect(warmCount.withLock { $0 } == 1)

		// Idle unload resets warmed state and drops the model.
		slot.unloadIfIdle(for: 0)
		#expect(slot.ifLoaded { _ in true } == nil)

		let postUnload = slot.warmUpOnce { _ in
			warmCount.withLock { $0 += 1 }
			return true
		}
		#expect(postUnload)
		#expect(loadCount.withLock { $0 } == 2)
		#expect(warmCount.withLock { $0 } == 2)
	}

	@Test func warmUpOnceRetriesAfterBodyFailureAndNilLoad() {
		let canLoad = Mutex(false)
		let loadCount = Mutex(0)
		let warmAttempts = Mutex(0)

		let slot = ModelSlot<String> {
			guard canLoad.withLock({ $0 }) else { return nil }
			loadCount.withLock { $0 += 1 }
			return "model"
		}

		let nilAttempt = slot.warmUpOnce { _ in
			warmAttempts.withLock { $0 += 1 }
			return true
		}
		#expect(!nilAttempt)
		#expect(warmAttempts.withLock { $0 } == 0)

		canLoad.withLock { $0 = true }

		let failedWarm = slot.warmUpOnce { _ in
			warmAttempts.withLock { $0 += 1 }
			return false
		}
		#expect(!failedWarm)
		#expect(loadCount.withLock { $0 } == 1)
		#expect(warmAttempts.withLock { $0 } == 1)

		let retriedWarm = slot.warmUpOnce { _ in
			warmAttempts.withLock { $0 += 1 }
			return true
		}
		#expect(retriedWarm)
		#expect(loadCount.withLock { $0 } == 1)
		#expect(warmAttempts.withLock { $0 } == 2)

		let settledWarm = slot.warmUpOnce { _ in
			warmAttempts.withLock { $0 += 1 }
			return true
		}
		#expect(settledWarm)
		#expect(warmAttempts.withLock { $0 } == 2)
	}

	@Test func faceprintSimilarityMatchesScalarCosineAcrossNormalAndEdgeVectors() {
		let source = "coreml:112x112:test"
		let pairs: [([Float], [Float])] = [
			([1], [1]),
			([3, 4], [4, 3]),
			([1, 0], [0, 1]),
			([1, 0], [-1, 0]),
			((0..<128).map { Float(sin(Double($0) * 0.37)) }, (0..<128).map { Float(cos(Double($0) * 0.21)) }),
			((0..<512).map { Float(sin(Double($0 * 13 + 5)) * 2.5) }, (0..<512).map { Float(cos(Double($0 * 7 + 1)) * 0.4) }),
		]

		for (lhs, rhs) in pairs {
			let a = Faceprint(values: lhs, source: source)
			let b = Faceprint(values: rhs, source: source)
			let expected = naiveScalarCosine(lhs, rhs)
			let actual = a.similarity(to: b)
			#expect(abs(actual - expected) < 1e-5)
		}

		// Edge cases: zero, non-finite, empty, mismatched source, mismatched length.
		let unit = Faceprint(values: [0.6, 0.8, 0, 0], source: source)
		#expect(Faceprint(values: [0, 0, 0, 0], source: source).similarity(to: unit) == 0)
		#expect(unit.similarity(to: Faceprint(values: [0, 0, 0, 0], source: source)) == 0)
		#expect(Faceprint(values: [.nan, 1, 0, 0], source: source).similarity(to: unit) == 0)
		#expect(unit.similarity(to: Faceprint(values: [0, .infinity, 0, 0], source: source)) == 0)
		#expect(Faceprint(values: [-.infinity, 1, 0, 0], source: source).similarity(to: unit) == 0)
		#expect(Faceprint(values: [.greatestFiniteMagnitude, 1, 0, 0], source: source).similarity(to: unit) == 0)
		#expect(Faceprint(values: [], source: source).similarity(to: Faceprint(values: [], source: source)) == 0)
		#expect(Faceprint(values: [1, 0], source: "").similarity(to: Faceprint(values: [1, 0], source: "")) == 0)
		#expect(unit.similarity(to: Faceprint(values: unit.values, source: "coreml:other")) == 0)
		#expect(unit.similarity(to: Faceprint(values: [1, 0], source: source)) == 0)
	}

	@Test func extractFloatsMatchesSubscriptForContiguousFloat32AndFloat16AndStridedFallbacks() throws {
		// Contiguous Float32 [1, 512]
		let f32 = try MLMultiArray(shape: [1, 512], dataType: .float32)
		for i in 0..<f32.count {
			f32[i] = NSNumber(value: Float(sin(Double(i) * 0.19) * 3.25))
		}
		let expectedF32 = (0..<f32.count).map { f32[$0].floatValue }
		#expect(CoreMLEmbedder.extractFloats(from: f32) == expectedF32)

		// Contiguous Float16 [1, 512] (including -0.0 and fractional values)
		let f16 = try MLMultiArray(shape: [1, 512], dataType: .float16)
		for i in 0..<f16.count {
			let value: Float = i == 0 ? -0.0 : Float(cos(Double(i) * 0.23) * 12.5)
			f16[i] = NSNumber(value: value)
		}
		let expectedF16 = (0..<f16.count).map { f16[$0].floatValue }
		#expect(CoreMLEmbedder.extractFloats(from: f16) == expectedF16)

		// Non-contiguous Float32 (row stride 4 for 3 columns, skipping padding 999 / 888)
		var paddedF32: [Float] = [1.25, -2.5, 3.75, 999.0, 4.5, -5.25, 6.125, 888.0]
		try withStridedMultiArray(
			backing: &paddedF32,
			shape: [2, 3],
			dataType: .float32,
			strides: [4, 1]
		) { stridedF32 in
			#expect(CoreMLEmbedder.extractFloats(from: stridedF32) == [1.25, -2.5, 3.75, 4.5, -5.25, 6.125])
		}

		// Transposed non-contiguous Float32 (strides [1, 2] on shape [2, 3])
		var transposedBacking: [Float] = [10, 20, 30, 40, 50, 60]
		try withStridedMultiArray(
			backing: &transposedBacking,
			shape: [2, 3],
			dataType: .float32,
			strides: [1, 2]
		) { transposedF32 in
			let expectedTransposed = (0..<transposedF32.count).map { transposedF32[$0].floatValue }
			#expect(CoreMLEmbedder.extractFloats(from: transposedF32) == expectedTransposed)
		}

		// Non-contiguous Float16 (row stride 4 for 3 columns)
		var paddedF16Raw: [UInt16] = [0x3c00, 0x4000, 0x4200, 0x7c00, 0xc400, 0xc600, 0x3800, 0x7e00]
		try withStridedMultiArray(
			backing: &paddedF16Raw,
			shape: [2, 3],
			dataType: .float16,
			strides: [4, 1]
		) { stridedF16 in
			let expectedStridedF16 = (0..<stridedF16.count).map { stridedF16[$0].floatValue }
			#expect(CoreMLEmbedder.extractFloats(from: stridedF16) == expectedStridedF16)
		}

		// Other data type (.double / .int32) falls back to subscript safely
		let f64 = try MLMultiArray(shape: [2, 2], dataType: .double)
		for i in 0..<f64.count { f64[i] = NSNumber(value: Double(i) * 1.5 - 2.0) }
		#expect(CoreMLEmbedder.extractFloats(from: f64) == [-2.0, -0.5, 1.0, 2.5])
	}

	@Test func unlockFrameEvaluatorSharesSingleContextCropAndRecordsSpoofResult() async throws {
		let box = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
		let frameBuffer = try makePixelBuffer(width: 640, height: 480, fillByte: 120)
		let landmarks = try makeStubLandmarks(pixelBuffer: frameBuffer, boundingBox: box)
		let sample = FaceSample(
			landmarks: landmarks,
			boundingBox: box,
			pose: .zero,
			quality: 0.85,
			hasQualityMeasurement: true,
			pixelBuffer: frameBuffer
		)

		let enrolledPrint = Faceprint(values: [1, 0], source: "coreml:test")
		let mismatchedPrint = Faceprint(values: [0, 1], source: "coreml:test")
		let face = FaceEnrollment(name: "Owner", prints: [enrolledPrint], embedder: "coreml:test", cameraID: "cam")

		let cropCalls = Mutex(0)
		let builtCropInfo = Mutex<(id: ObjectIdentifier, width: Int, height: Int)?>(nil)
		let observedGateCropID = Mutex<ObjectIdentifier?>(nil)
		let gateConfidence = Mutex<Float?>(0.18)

		let gate = AntiSpoofGate(usesSharedContextCrop224: true) { _, crop in
			observedGateCropID.withLock { $0 = crop.map(ObjectIdentifier.init) }
			return gateConfidence.withLock { $0 }
		}

		let matchingEvaluator = UnlockFrameEvaluator(
			embedder: StubEmbedder(printToReturn: enrolledPrint),
			faces: [face],
			antiSpoof: gate,
			makeContextCrop: { sample, side in
				cropCalls.withLock { $0 += 1 }
				guard let rendered = FaceAligner.contextCrop(sample, side: side) else { return nil }
				builtCropInfo.withLock {
					$0 = (ObjectIdentifier(rendered), CVPixelBufferGetWidth(rendered), CVPixelBufferGetHeight(rendered))
				}
				return rendered
			}
		)

		let matchResult = await matchingEvaluator.evaluate(sample)
		#expect(matchResult.matched)
		#expect(matchResult.spoofDecision == .live)
		#expect(matchResult.didRunSpoofClassifier)
		#expect(matchResult.spoofConfidence == 0.18)
		#expect(cropCalls.withLock { $0 } == 1)

		let builtCrop = try #require(builtCropInfo.withLock { $0 })
		let seenCropID = try #require(observedGateCropID.withLock { $0 })
		#expect(builtCrop.id == seenCropID)
		#expect(builtCrop.width == 224)
		#expect(builtCrop.height == 224)

		// Non-matching frame skips denyChecked and invokes context crop builder 0 times.
		cropCalls.withLock { $0 = 0 }
		let nonMatchingEvaluator = UnlockFrameEvaluator(
			embedder: StubEmbedder(printToReturn: mismatchedPrint),
			faces: [face],
			antiSpoof: gate,
			makeContextCrop: { sample, side in
				cropCalls.withLock { $0 += 1 }
				return FaceAligner.contextCrop(sample, side: side)
			}
		)
		let missResult = await nonMatchingEvaluator.evaluate(sample)
		#expect(!missResult.matched)
		#expect(!missResult.didRunSpoofClassifier)
		#expect(missResult.spoofConfidence == nil)
		#expect(cropCalls.withLock { $0 } == 0)

		// Spoof-scored frame still shares the single crop and records confidence & classifier flag.
		cropCalls.withLock { $0 = 0 }
		gateConfidence.withLock { $0 = 0.95 }
		let spoofResult = await matchingEvaluator.evaluate(sample)
		#expect(spoofResult.matched)
		#expect(spoofResult.didRunSpoofClassifier)
		#expect(spoofResult.spoofConfidence == 0.95)
		if case .suspect(let score)? = spoofResult.spoofDecision {
			#expect(score == 0.95)
		} else {
			Issue.record("Expected .suspect(0.95) on first spoof frame, got \(String(describing: spoofResult.spoofDecision))")
		}
		#expect(cropCalls.withLock { $0 } == 1)
	}

	@Test func coreMLEmbedderDefersModelLoadAndFailsClosedOnInvalidBundleDirectory() throws {
		#expect(CoreMLEmbedder(modelURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).mlmodelc")) == nil)

		let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-face-embedding-\(UUID().uuidString).mlmodelc")
		try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempDir) }

		let embedder = try #require(CoreMLEmbedder(modelURL: tempDir))
		#expect(embedder.identifier == "coreml:112x112:\(CoreMLEmbedder.modelTag)")
		embedder.warmUp()

		let frameBuffer = try makePixelBuffer(width: 256, height: 256, fillByte: 120)
		let box = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
		let landmarks = try makeStubLandmarks(pixelBuffer: frameBuffer, boundingBox: box)
		let sample = FaceSample(
			landmarks: landmarks,
			boundingBox: box,
			pose: .zero,
			quality: 0.85,
			hasQualityMeasurement: true,
			pixelBuffer: frameBuffer
		)
		#expect(embedder.embed(sample) == nil)
	}

	@Test func unlockFrameEvaluatorRoutesSharedCropToDenyCuesAndHandlesNilAntiSpoof() async throws {
		let box = CGRect(x: 0.4, y: 0.38, width: 0.2, height: 0.25)
		let frameBuffer = try makePixelBuffer(width: 640, height: 480, fillByte: 120)
		let landmarks = try makeStubLandmarks(pixelBuffer: frameBuffer, boundingBox: box)
		let sample = FaceSample(
			landmarks: landmarks,
			boundingBox: box,
			pose: .zero,
			quality: 0.85,
			hasQualityMeasurement: true,
			pixelBuffer: frameBuffer
		)
		let enrolledPrint = Faceprint(values: [1, 0], source: "coreml:test")
		let face = FaceEnrollment(name: "Owner", prints: [enrolledPrint], embedder: "coreml:test", cameraID: "cam")

		// Nil antiSpoof leaves classifier flag false and never builds context crop.
		let cropCalls = Mutex(0)
		let noGateEvaluator = UnlockFrameEvaluator(
			embedder: StubEmbedder(printToReturn: enrolledPrint),
			faces: [face],
			antiSpoof: nil,
			makeContextCrop: { sample, side in
				cropCalls.withLock { $0 += 1 }
				return FaceAligner.contextCrop(sample, side: side)
			}
		)
		let noGateResult = await noGateEvaluator.evaluate(sample)
		#expect(noGateResult.matched)
		#expect(noGateResult.spoofDecision == nil)
		#expect(!noGateResult.didRunSpoofClassifier)
		#expect(noGateResult.spoofConfidence == nil)
		#expect(cropCalls.withLock { $0 } == 0)

		// Enclosing device-bezel rectangle in the shared 224x224 crop triggers DeviceBezelGate
		// after fireFrames frames while invoking makeContextCrop strictly once per frame.
		cropCalls.withLock { $0 = 0 }
		let bezelGate = AntiSpoofGate(usesSharedContextCrop224: true) { _, _ in 0.12 }
		let bezelEvaluator = UnlockFrameEvaluator(
			embedder: StubEmbedder(printToReturn: enrolledPrint),
			faces: [face],
			antiSpoof: bezelGate,
			makeContextCrop: { _, side in
				cropCalls.withLock { $0 += 1 }
				guard let crop = try? makePixelBuffer(width: side, height: side, fillByte: 0) else { return nil }
				if CVPixelBufferLockBaseAddress(crop, []) == kCVReturnSuccess {
					defer { CVPixelBufferUnlockBaseAddress(crop, []) }
					if let base = CVPixelBufferGetBaseAddress(crop) {
						let stride = CVPixelBufferGetBytesPerRow(crop)
						let bytes = base.assumingMemoryBound(to: UInt8.self)
						for y in 20..<204 {
							for x in 30..<194 {
								let px = bytes + y * stride + x * 4
								px[0] = 255
								px[1] = 255
								px[2] = 255
								px[3] = 255
							}
						}
					}
				}
				return crop
			}
		)

		var finalDecision: AntiSpoofGate.Decision?
		for _ in 0..<DeviceBezelGate.fireFrames {
			let result = await bezelEvaluator.evaluate(sample)
			#expect(result.didRunSpoofClassifier)
			#expect(result.spoofConfidence == 0.12)
			finalDecision = result.spoofDecision
		}
		#expect(cropCalls.withLock { $0 } == DeviceBezelGate.fireFrames)
		if case .spoof(let reason, _)? = finalDecision {
			#expect(reason.contains("device-bezel"))
		} else {
			Issue.record("Expected device-bezel .spoof decision, got \(String(describing: finalDecision))")
		}
	}

	@Test func antiSpoofGateTwoArgEvaluatePreservesFailClosedThresholds() throws {
		let frameBuffer = try makePixelBuffer(width: 64, height: 64, fillByte: 120)
		let box = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
		let landmarks = try makeStubLandmarks(pixelBuffer: frameBuffer, boundingBox: box)
		let sample = FaceSample(
			landmarks: landmarks,
			boundingBox: box,
			pose: .zero,
			quality: 0.85,
			hasQualityMeasurement: true,
			pixelBuffer: frameBuffer
		)

		let disabled = AntiSpoofGate(spoof: nil)
		#expect(disabled.evaluate(sample, contextCrop: nil) == (.unavailable, nil))
		#expect(disabled.evaluate(sample) == .unavailable)

		for badScore: Float in [.nan, .infinity, -.infinity, -0.01, 1.01] {
			let badGate = AntiSpoofGate { _, _ in badScore }
			#expect(badGate.evaluate(sample, contextCrop: nil) == (.unavailable, nil))
		}

		let nilScoreGate = AntiSpoofGate { _, _ in nil }
		#expect(nilScoreGate.evaluate(sample, contextCrop: nil) == (.unavailable, nil))

		let liveGate = AntiSpoofGate { _, _ in 0.89 }
		#expect(liveGate.evaluate(sample, contextCrop: frameBuffer) == (.live, 0.89))
		#expect(liveGate.evaluate(sample) == .live)

		let spoofGate = AntiSpoofGate { _, _ in 0.90 }
		let (decision, confidence) = spoofGate.evaluate(sample, contextCrop: frameBuffer)
		#expect(confidence == 0.90)
		if case .spoof(_, let score) = decision {
			#expect(score == 0.90)
		} else {
			Issue.record("Expected .spoof at 0.90 threshold, got \(decision)")
		}
	}
}
