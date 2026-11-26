import CoreGraphics
import CoreVideo
import GazeCamera
import GazeCore
import Synchronization
import Testing
import Vision

private enum StubVisionError: Error {
	case detectionFailed
}

private final class CountingVisionRunner: FaceVisionRunning, @unchecked Sendable {
	struct Counts: Sendable, Equatable {
		var rectangles = 0
		var landmarksAndQuality = 0
	}

	private let counts = Mutex(Counts())
	private let faces: [VNFaceObservation]
	private let shouldThrowOnDetect: Bool

	init(faces: [VNFaceObservation], shouldThrowOnDetect: Bool = false) {
		self.faces = faces
		self.shouldThrowOnDetect = shouldThrowOnDetect
	}

	var recordedCounts: Counts {
		counts.withLock { $0 }
	}

	func detectRectangles(using request: VNDetectFaceRectanglesRequest) throws -> [VNFaceObservation] {
		counts.withLock { $0.rectangles += 1 }
		if shouldThrowOnDetect {
			throw StubVisionError.detectionFailed
		}
		return faces
	}

	func analyseFace(
		_ face: VNFaceObservation,
		using landmarksRequest: VNDetectFaceLandmarksRequest,
		qualityRequest: VNDetectFaceCaptureQualityRequest,
		buffer: CVPixelBuffer
	) -> FaceSample? {
		counts.withLock { $0.landmarksAndQuality += 1 }
		return nil
	}
}

private func makeStubPixelBuffer() throws -> CVPixelBuffer {
	var pixelBuffer: CVPixelBuffer?
	let status = CVPixelBufferCreate(
		kCFAllocatorDefault,
		32,
		32,
		kCVPixelFormatType_32BGRA,
		nil,
		&pixelBuffer
	)
	#expect(status == kCVReturnSuccess)
	return try #require(pixelBuffer)
}

@Suite("Camera Backpressure & Presence-Only Pipeline")
struct CameraBackpressureTests {
	@Test func mailboxRetainsOnlyLatestElementAndCountsDroppedFrames() throws {
		let mailbox = LatestFrameMailbox<Int>()

		#expect(mailbox.enqueue(1) == true)
		#expect(mailbox.enqueue(2) == false)
		#expect(mailbox.enqueue(3) == false)
		#expect(mailbox.enqueue(4) == false)
		#expect(mailbox.enqueue(5) == false)

		let first = try #require(mailbox.take())
		#expect(first.element == 5)
		#expect(first.droppedBefore == 4)
		#expect(mailbox.take() == nil)
	}

	@Test func mailboxReentrancyNeverStrandsFramesArrivingDuringProcessing() throws {
		let mailbox = LatestFrameMailbox<String>()

		#expect(mailbox.enqueue("frame-1") == true)
		#expect(mailbox.enqueue("frame-2") == false)

		let taken = try #require(mailbox.take())
		#expect(taken.element == "frame-2")
		#expect(taken.droppedBefore == 1)

		// Producer pushes new frames while consumer is processing `taken`:
		// the first must signal a new drain task, subsequent overwrites must not.
		#expect(mailbox.enqueue("frame-3") == true)
		#expect(mailbox.enqueue("frame-4") == false)

		let followUp = try #require(mailbox.take())
		#expect(followUp.element == "frame-4")
		#expect(followUp.droppedBefore == 1)
		#expect(mailbox.take() == nil)
	}

	@Test func mailboxClearDiscardsPendingItemAndResetsScheduleState() {
		let mailbox = LatestFrameMailbox<Int>()

		#expect(mailbox.enqueue(10) == true)
		#expect(mailbox.enqueue(20) == false)
		mailbox.clear()

		#expect(mailbox.take() == nil)
		#expect(mailbox.enqueue(30) == true)
		let afterClear = mailbox.take()
		#expect(afterClear?.element == 30)
		#expect(afterClear?.droppedBefore == 0)
	}

	@Test func mailboxPreservesTotalAccountingAcrossConcurrentProducers() async {
		let mailbox = LatestFrameMailbox<Int>()
		let totalFrames = 200
		let delivered = Mutex(0)
		let dropped = Mutex(0)
		let lastSeen = Mutex(0)

		await withTaskGroup(of: Void.self) { group in
			group.addTask {
				for frame in 1...totalFrames {
					_ = mailbox.enqueue(frame)
					if frame % 10 == 0 {
						await Task.yield()
					}
				}
			}
			group.addTask {
				while lastSeen.withLock({ $0 }) < totalFrames {
					if let batch = mailbox.take() {
						delivered.withLock { $0 += 1 }
						dropped.withLock { $0 += batch.droppedBefore }
						lastSeen.withLock { $0 = max($0, batch.element) }
					} else {
						await Task.yield()
					}
				}
			}
		}

		let totalDelivered = delivered.withLock { $0 }
		let totalDropped = dropped.withLock { $0 }
		#expect(lastSeen.withLock { $0 } == totalFrames)
		#expect(totalDelivered + totalDropped == totalFrames)
	}

	@Test func continuityInvalidatesPriorProofWhenFramesWereDroppedEvenWithinGapBudget() {
		var continuity = CameraEvidenceContinuity()
		let t0 = ContinuousClock.now
		let firstAccepted = continuity.record(usable: true, capturedAt: t0)
		#expect(firstAccepted)
		let priorRevision = continuity.revision
		#expect(continuity.permits(priorRevision, at: t0))

		// 33ms is well inside CameraEvidenceContinuity.maximumGap (240ms),
		// yet droppedBefore > 0 means intervening frames were missed.
		let t1 = t0.advanced(by: .milliseconds(33))
		let postDropAccepted = continuity.record(usable: true, capturedAt: t1, droppedBefore: 1)
		#expect(postDropAccepted)
		#expect(!continuity.permits(priorRevision, at: t1))

		let freshRevision = continuity.revision
		#expect(freshRevision != priorRevision)
		#expect(continuity.permits(freshRevision, at: t1))

		// Out-of-order timestamp with droppedBefore > 0 still fails closed.
		let outOfOrderAccepted = continuity.record(usable: true, capturedAt: t1, droppedBefore: 1)
		#expect(!outOfOrderAccepted)
		#expect(!continuity.permits(continuity.revision, at: t1))

		// Unusable (e.g. presenceOnly or quality-rejected) frames never satisfy recognition continuity.
		let t2 = t1.advanced(by: .milliseconds(33))
		let unusableAccepted = continuity.record(usable: false, capturedAt: t2, droppedBefore: 0)
		#expect(unusableAccepted)
		#expect(!continuity.permits(continuity.revision, at: t2))
	}

	@Test(arguments: [
		(0, true, PresenceObservation.Verdict.noFace),
		(1, true, PresenceObservation.Verdict.facePresent),
		(2, true, PresenceObservation.Verdict.facePresent),
		(5, true, PresenceObservation.Verdict.facePresent),
		(0, false, PresenceObservation.Verdict.indeterminate),
		(1, false, PresenceObservation.Verdict.indeterminate),
		(-1, true, PresenceObservation.Verdict.indeterminate),
	])
	func sampleProxyPresenceVerdictMapsCountsAndErrors(
		detectedCount: Int,
		detectionSucceeded: Bool,
		expected: PresenceObservation.Verdict
	) {
		#expect(
			SampleProxy.presenceVerdict(detectedCount: detectedCount, detectionSucceeded: detectionSucceeded) == expected
		)
	}

	@Test func sampleProxyPresenceOnlyRunsZeroLandmarkOrQualityRequests() throws {
		let buffer = try makeStubPixelBuffer()
		let face = VNFaceObservation(boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.4, height: 0.4))
		let observed = Mutex<[SampleProxy.Output]>([])

		let runnerWithFaces = CountingVisionRunner(faces: [face, face])
		let presenceProxy = SampleProxy(
			analysisMode: .presenceOnly,
			allowsBystanders: true,
			makeVisionRunner: { _ in runnerWithFaces },
			onOutput: { output in observed.withLock { $0.append(output) } }
		)
		let t1 = ContinuousClock.now
		presenceProxy.process(buffer: buffer, capturedAt: t1)

		let runnerEmpty = CountingVisionRunner(faces: [])
		let emptyProxy = SampleProxy(
			analysisMode: .presenceOnly,
			allowsBystanders: true,
			makeVisionRunner: { _ in runnerEmpty },
			onOutput: { output in observed.withLock { $0.append(output) } }
		)
		let t2 = t1.advanced(by: .milliseconds(33))
		emptyProxy.process(buffer: buffer, capturedAt: t2)

		let runnerError = CountingVisionRunner(faces: [], shouldThrowOnDetect: true)
		let errorProxy = SampleProxy(
			analysisMode: .presenceOnly,
			allowsBystanders: true,
			makeVisionRunner: { _ in runnerError },
			onOutput: { output in observed.withLock { $0.append(output) } }
		)
		let t3 = t2.advanced(by: .milliseconds(33))
		errorProxy.process(buffer: buffer, capturedAt: t3)

		let runnerStrictBystanders = CountingVisionRunner(faces: [face, face])
		let strictPresenceProxy = SampleProxy(
			analysisMode: .presenceOnly,
			allowsBystanders: false,
			makeVisionRunner: { _ in runnerStrictBystanders },
			onOutput: { output in observed.withLock { $0.append(output) } }
		)
		let t4 = t3.advanced(by: .milliseconds(33))
		strictPresenceProxy.process(buffer: buffer, capturedAt: t4)

		#expect(runnerWithFaces.recordedCounts == .init(rectangles: 1, landmarksAndQuality: 0))
		#expect(runnerEmpty.recordedCounts == .init(rectangles: 1, landmarksAndQuality: 0))
		#expect(runnerError.recordedCounts == .init(rectangles: 1, landmarksAndQuality: 0))
		#expect(runnerStrictBystanders.recordedCounts == .init(rectangles: 1, landmarksAndQuality: 0))

		let outputs = observed.withLock { $0 }
		#expect(outputs.count == 4)
		guard outputs.count == 4 else { return }
		if case .presence(let verdict, let capturedAt) = outputs[0] {
			#expect(verdict == .facePresent)
			#expect(capturedAt == t1)
		} else {
			Issue.record("Expected .presence output for facePresent")
		}
		if case .presence(let verdict, let capturedAt) = outputs[1] {
			#expect(verdict == .noFace)
			#expect(capturedAt == t2)
		} else {
			Issue.record("Expected .presence output for noFace")
		}
		if case .presence(let verdict, let capturedAt) = outputs[2] {
			#expect(verdict == .indeterminate)
			#expect(capturedAt == t3)
		} else {
			Issue.record("Expected .presence output for indeterminate")
		}
		if case .presence(let verdict, let capturedAt) = outputs[3] {
			#expect(verdict == .facePresent)
			#expect(capturedAt == t4)
		} else {
			Issue.record("Expected .presence output for strict-bystander facePresent")
		}
	}

	@Test func sampleProxyFullModeInvokesLandmarkAndQualityAnalysisWhenFaceFound() throws {
		let buffer = try makeStubPixelBuffer()
		let face = VNFaceObservation(boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.4, height: 0.4))
		let runner = CountingVisionRunner(faces: [face])
		let outputs = Mutex<[SampleProxy.Output]>([])

		let fullProxy = SampleProxy(
			analysisMode: .full,
			allowsBystanders: false,
			makeVisionRunner: { _ in runner },
			onOutput: { output in outputs.withLock { $0.append(output) } }
		)
		fullProxy.process(buffer: buffer, capturedAt: .now)

		#expect(runner.recordedCounts == .init(rectangles: 1, landmarksAndQuality: 1))

		let multiFaceRunner = CountingVisionRunner(faces: [face, face])
		let strictMultiProxy = SampleProxy(
			analysisMode: .full,
			allowsBystanders: false,
			makeVisionRunner: { _ in multiFaceRunner },
			onOutput: { output in outputs.withLock { $0.append(output) } }
		)
		strictMultiProxy.process(buffer: buffer, capturedAt: .now)
		#expect(multiFaceRunner.recordedCounts == .init(rectangles: 1, landmarksAndQuality: 0))
		if case .full(let sample, let absence, _)? = outputs.withLock({ $0.last }) {
			#expect(sample == nil)
			#expect(absence == .multipleFaces(2))
		} else {
			Issue.record("Expected .full multipleFaces(2) output")
		}
	}

	@Test @MainActor func cameraControllerExposesAnalysisModeAndPresenceCallback() {
		let defaultController = CameraController()
		#expect(defaultController.analysisMode == .full)

		let presenceController = CameraController(
			accessScope: .foreground,
			allowsBystanders: true,
			analysisMode: .presenceOnly
		)
		#expect(presenceController.analysisMode == .presenceOnly)
		presenceController.onPresenceObserved = { _ in }
		presenceController.stop()
		#expect(presenceController.state == .idle)
	}
}
