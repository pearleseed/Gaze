import CoreGraphics
import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import GazeRecognition
import Synchronization
import Testing
import Vision
@testable import GazeApp

private final class EnrollmentFixtureEmbedder: FaceEmbedder {
	let identifier = "fixture-embedder"
	let usesCosineSimilarity = true
	let matchThreshold: Float = 0.5

	private struct State {
		var available = true
		var calls = 0
	}

	private let state = Mutex(State())

	var available: Bool {
		get { state.withLock { $0.available } }
		set { state.withLock { $0.available = newValue } }
	}

	var calls: Int {
		state.withLock { $0.calls }
	}

	func embed(_ sample: FaceSample) -> Faceprint? {
		state.withLock {
			$0.calls += 1
			return $0.available ? Faceprint(values: [1, 0], source: identifier) : nil
		}
	}

	func similarity(_ a: Faceprint, _ b: Faceprint) -> Float {
		zip(a.values, b.values).reduce(0) { $0 + $1.0 * $1.1 }
	}
}

@MainActor
private final class AsyncTestGate {
	var continuation: CheckedContinuation<Void, Never>?
	func wait() async { await withCheckedContinuation { continuation = $0 } }
	func release() { continuation?.resume(); continuation = nil }
}

@Suite("Enrollment Model & Setup Session Lifecycle")
struct EnrollmentModelTests {
	private nonisolated static func makeBaseFixture() throws -> (CVPixelBuffer, VNFaceLandmarks2D) {
		var pixelBuffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
		)
		#expect(status == kCVReturnSuccess)
		let buffer = try #require(pixelBuffer)
		let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
		let face = VNFaceObservation(boundingBox: box)
		let request = VNDetectFaceLandmarksRequest()
		request.inputFaceObservations = [face]
		try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
		let landmarks = try #require(request.results?.first?.landmarks)
		return (buffer, landmarks)
	}

	private func makeSample(
		buffer: CVPixelBuffer,
		landmarks: VNFaceLandmarks2D,
		boundingBox: CGRect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
		quality: Float = 0.8,
		pose: FacePose = .zero
	) -> FaceSample {
		FaceSample(
			landmarks: landmarks,
			boundingBox: boundingBox,
			pose: pose,
			quality: quality,
			hasQualityMeasurement: true,
			pixelBuffer: buffer
		)
	}

	@Test @MainActor func twoPassCaptureValidationAndReset() throws {
		let (buffer, landmarks) = try Self.makeBaseFixture()
		let frontal = makeSample(buffer: buffer, landmarks: landmarks)
		let blurred = makeSample(buffer: buffer, landmarks: landmarks, quality: 0.34)
		let turned = makeSample(buffer: buffer, landmarks: landmarks, pose: FacePose(yaw: 0.3, pitch: 0, roll: 0))

		let embedder = EnrollmentFixtureEmbedder()
		let model = EnrollmentModel(embedder: embedder)

		for _ in 0..<5 { model.consume(frontal) }
		#expect(model.phase == .positioning && embedder.calls == 0)

		model.consume(blurred)
		model.consume(frontal)
		#expect(model.phase == .positioning)

		for _ in 0..<4 { model.consume(frontal) }
		embedder.available = false
		model.consume(frontal)
		#expect(model.phase == .positioning && model.prints.isEmpty)

		embedder.available = true
		model.consume(frontal)
		#expect(model.phase == .capturing(pass: 1) && model.prints.count == 1)
		#expect(model.progress == 0)

		embedder.available = false
		model.consume(turned)
		#expect(model.progress == 0 && model.prints.count == 1)

		embedder.available = true
		model.consume(turned)
		#expect(model.progress > 0 && model.prints.count == 2)

		let savedProgress = model.progress
		let savedCalls = embedder.calls
		model.consume(turned)
		#expect(model.progress == savedProgress && embedder.calls == savedCalls)

		for value: Double in [.nan, .infinity, -.infinity] {
			for pose in [
				FacePose(yaw: value, pitch: 0, roll: 0),
				FacePose(yaw: 0.3, pitch: value, roll: 0),
				FacePose(yaw: 0.3, pitch: 0, roll: value),
			] {
				model.consume(makeSample(buffer: buffer, landmarks: landmarks, pose: pose))
				#expect(model.currentAngle.isFinite && !model.isEngaged)
				#expect(model.progress == savedProgress && embedder.calls == savedCalls)
			}
		}

		for quality: Float in [.nan, .infinity, -1, 0, 0.34, 1.1] {
			model.consume(makeSample(buffer: buffer, landmarks: landmarks, quality: quality, pose: FacePose(yaw: 0.3, pitch: 0, roll: 0)))
			#expect(model.progress == savedProgress && embedder.calls == savedCalls)
		}

		model.consume(
			makeSample(
				buffer: buffer,
				landmarks: landmarks,
				boundingBox: CGRect(x: -0.1, y: 0.2, width: 0.4, height: 0.4),
				pose: FacePose(yaw: 0.3, pitch: 0, roll: 0)
			)
		)
		#expect(model.progress == savedProgress && embedder.calls == savedCalls)

		model.consume(nil)
		#expect(model.phase == .capturing(pass: 1) && model.progress == savedProgress)

		// Two passes, like Face ID: the first full ring starts the second.
		for lap in 0..<2 {
			if lap == 1 {
				#expect(model.phase != .complete)
				for _ in 0..<8 where model.phase == .positioning { model.consume(frontal) }
			}
			for segment in 0..<EnrollmentModel.segmentCount {
				let angle = Double(segment) * 2 * .pi / Double(EnrollmentModel.segmentCount)
				let pose = FacePose(yaw: -sin(angle) * 0.3, pitch: -cos(angle) * 0.3, roll: 0)
				model.consume(makeSample(buffer: buffer, landmarks: landmarks, pose: pose))
				if model.phase == .complete { break }
			}
		}
		#expect(model.phase == .complete)
		#expect(model.prints.count >= 8)

		let completedPrints = model.prints
		model.consume(nil)
		model.consume(turned)
		#expect(model.phase == .complete && model.prints == completedPrints)

		model.reset()
		#expect(
			model.phase == .positioning && model.prints.isEmpty && model.progress == 0
				&& model.currentAngle == 0 && !model.isEngaged
		)
	}

	@Test @MainActor func guidanceGapHighlightingAndStallCompletion() throws {
		let (buffer, landmarks) = try Self.makeBaseFixture()
		let frontal = makeSample(buffer: buffer, landmarks: landmarks)
		let blurred = makeSample(buffer: buffer, landmarks: landmarks, quality: 0.34)
		let small = makeSample(buffer: buffer, landmarks: landmarks, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.1))

		let guidanceEmbedder = EnrollmentFixtureEmbedder()
		let guidance = EnrollmentModel(embedder: guidanceEmbedder)
		let base = Date()
		guidance.now = { base }

		for _ in 0..<9 { guidance.consume(frontal) }
		#expect(guidance.captureStatus == .steady && guidance.instruction.contains("Gently turn"))

		// Complete first pass.
		for segment in 0..<48 {
			let angle = (Double(segment) + 0.5) * 2 * .pi / 48
			let pose = FacePose(yaw: -sin(angle) * 0.3, pitch: -cos(angle) * 0.3, roll: 0)
			guidance.consume(makeSample(buffer: buffer, landmarks: landmarks, pose: pose))
		}
		#expect(guidance.phase == .capturing(pass: 2))

		// Fill pass 2 leaving gap 10...19.
		for segment in 0..<48 where !(10...19).contains(segment) {
			let angle = (Double(segment) + 0.5) * 2 * .pi / 48
			let pose = FacePose(yaw: -sin(angle) * 0.3, pitch: -cos(angle) * 0.3, roll: 0)
			guidance.consume(makeSample(buffer: buffer, landmarks: landmarks, pose: pose))
		}
		#expect(guidance.phase == .capturing(pass: 2) && guidance.progress > 0.75 && guidance.progress < 0.85)
		#expect(guidance.targetSegment != nil && guidance.instruction.contains("fill the circle"))

		let gapProgress = guidance.progress
		let gapPrints = guidance.prints
		guidance.consume(blurred)
		#expect(guidance.captureStatus == .lowQuality && guidance.instruction.contains("Face a light"))
		#expect(!guidance.instruction.contains("toward the gap"))

		guidance.consume(nil)
		#expect(guidance.captureStatus == .noFace)
		#expect(guidance.progress == gapProgress && guidance.prints == gapPrints)

		guidance.consume(small)
		#expect(guidance.captureStatus == .tooSmall)

		guidanceEmbedder.available = false
		if let target = guidance.targetSegment {
			let angle = (Double(target) + 0.5) * 2 * .pi / 48
			let pose = FacePose(yaw: -sin(angle) * 0.3, pitch: -cos(angle) * 0.3, roll: 0)
			guidance.consume(makeSample(buffer: buffer, landmarks: landmarks, pose: pose))
		}
		#expect(guidance.captureStatus == .embeddingUnavailable)
		#expect(guidance.progress == gapProgress)

		guidanceEmbedder.available = true
		guidance.now = { base.addingTimeInterval(4) }
		guidance.consume(frontal)
		#expect(guidance.instruction.contains("toward the gap"))

		guidance.now = { base }
		for _ in 0..<2 {
			guard let target = guidance.targetSegment else { break }
			#expect(!guidance.covered[target])
			let angle = (Double(target) + 0.5) * 2 * .pi / 48
			let pose = FacePose(yaw: -sin(angle) * 0.3, pitch: -cos(angle) * 0.3, roll: 0)
			guidance.consume(makeSample(buffer: buffer, landmarks: landmarks, pose: pose))
		}
		#expect(guidance.phase == .capturing(pass: 2) && guidance.progress < 1)

		guidance.now = { base.addingTimeInterval(10) }
		let repeatPose = FacePose(yaw: -sin(0.5) * 0.3, pitch: -cos(0.5) * 0.3, roll: 0)
		guidance.consume(makeSample(buffer: buffer, landmarks: landmarks, pose: repeatPose))
		#expect(guidance.phase == .complete)
		#expect(guidance.targetSegment == nil)
		#expect(guidance.covered.allSatisfy { $0 })
	}

	@MainActor
	private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
		for _ in 0..<400 {
			if condition() { return }
			try? await Task.sleep(for: .milliseconds(2))
		}
		#expect(condition(), "Async fixture did not reach its expected state")
	}

	@Test @MainActor func setupSessionWorkCancellationIsolationAndDeinit() async {
		let work = SetupSessionWork()
		let original = work.revision
		var started = false
		work.run { _ in started = true }
		work.cancel()
		await Task.yield()
		#expect(!started && work.activeCount == 0 && !work.isCurrent(original))

		var cancelled = false
		work.run { _ in
			started = true
			do { try await Task.sleep(for: .seconds(60)) }
			catch is CancellationError { cancelled = true }
			catch { Issue.record("Unexpected fixture error: \(error)") }
		}
		await waitUntil { started }
		work.cancel()
		await waitUntil { cancelled }
		#expect(work.activeCount == 0)

		let stale = AsyncTestGate()
		var applied = false
		var staleFinished = false
		work.run { token in
			await stale.wait()
			if work.isCurrent(token) { applied = true }
			staleFinished = true
		}
		await waitUntil { stale.continuation != nil }
		work.cancel()
		let reopenedRevision = work.revision
		var reopenedApplied = false
		work.run { token in reopenedApplied = work.isCurrent(token) }
		stale.release()
		await waitUntil { reopenedApplied && staleFinished && work.activeCount == 0 }
		#expect(!applied && work.isCurrent(reopenedRevision))

		let first = AsyncTestGate()
		let second = AsyncTestGate()
		work.run { _ in await first.wait() }
		work.run { _ in await second.wait() }
		await waitUntil { first.continuation != nil && second.continuation != nil }
		#expect(work.activeCount == 2)
		first.release()
		await waitUntil { work.activeCount == 1 }
		second.release()
		await waitUntil { work.activeCount == 0 }

		var lifetime: SetupSessionWork? = SetupSessionWork()
		var lifetimeStarted = false
		var lifetimeCancelled = false
		lifetime?.run { _ in
			lifetimeStarted = true
			do { try await Task.sleep(for: .seconds(60)) }
			catch is CancellationError { lifetimeCancelled = true }
			catch { Issue.record("Unexpected fixture error: \(error)") }
		}
		await waitUntil { lifetimeStarted }
		lifetime = nil
		await waitUntil { lifetimeCancelled }
	}
}
