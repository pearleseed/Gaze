import CoreGraphics
import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import Testing
import Vision

@Suite("Camera Evidence Continuity & Frame Quality")
struct ContinuityTests {
	private func makeSample(
		boundingBox: CGRect = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
		pose: FacePose = .zero,
		quality: Float = 0.7,
		hasQualityMeasurement: Bool = true
	) throws -> FaceSample {
		var pixelBuffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
		)
		#expect(status == kCVReturnSuccess)
		let buffer = try #require(pixelBuffer)
		let face = VNFaceObservation(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
		let request = VNDetectFaceLandmarksRequest()
		request.inputFaceObservations = [face]
		try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
		let landmarks = try #require(request.results?.first?.landmarks)
		return FaceSample(
			landmarks: landmarks,
			boundingBox: boundingBox,
			pose: pose,
			quality: quality,
			hasQualityMeasurement: hasQualityMeasurement,
			pixelBuffer: buffer
		)
	}

	@Test func cameraEvidenceContinuityBoundariesAndRecovery() {
		let now = ContinuousClock.now
		var evidence = CameraEvidenceContinuity()
		#expect(!evidence.permits(evidence.revision, at: now), "No camera evidence fails closed")
		evidence.record(usable: true, capturedAt: now)
		let token = evidence.revision
		#expect(evidence.permits(token, at: now), "Fresh usable sample is current")
		evidence.record(usable: true, capturedAt: now.advanced(by: .milliseconds(100)))
		#expect(evidence.permits(token, at: now.advanced(by: .milliseconds(110))), "Continuous camera preserves in-flight proof")
		evidence.record(usable: false, capturedAt: now.advanced(by: .milliseconds(150)))
		#expect(!evidence.permits(token, at: now.advanced(by: .milliseconds(150))), "Bad frame invalidates inference")
		evidence.record(usable: true, capturedAt: now.advanced(by: .milliseconds(200)))
		#expect(!evidence.permits(token, at: now.advanced(by: .milliseconds(200))), "Recovery never restores previous proof")
		let recovered = evidence.revision
		#expect(evidence.permits(recovered, at: now.advanced(by: .milliseconds(200))), "Recovered stream can start fresh verification")
		evidence.record(usable: true, capturedAt: now.advanced(by: .milliseconds(441)))
		#expect(!evidence.permits(recovered, at: now.advanced(by: .milliseconds(441))), "Camera gap breaks continuity")
		let afterGap = evidence.revision
		#expect(!evidence.permits(afterGap, at: now.advanced(by: .milliseconds(400))), "Future capture is denied")
		#expect(!evidence.permits(afterGap, at: now.advanced(by: .milliseconds(942))), "Old capture is denied")
		let outOfOrder = evidence.record(usable: true, capturedAt: now.advanced(by: .milliseconds(440)))
		#expect(!outOfOrder, "Out-of-order callback rejected")
		#expect(!evidence.permits(evidence.revision, at: now.advanced(by: .milliseconds(450))), "Rejected callback cannot leave usable evidence")
		evidence.record(usable: true, capturedAt: now.advanced(by: .milliseconds(500)))
		let beforeStop = evidence.revision
		evidence.invalidate()
		evidence.record(usable: true, capturedAt: now.advanced(by: .milliseconds(550)))
		#expect(!evidence.permits(beforeStop, at: now.advanced(by: .milliseconds(550))), "Stop/restart invalidates old results")

		var boundary = CameraEvidenceContinuity()
		boundary.record(usable: true, capturedAt: now)
		let boundaryToken = boundary.revision
		#expect(boundary.permits(boundaryToken, at: now.advanced(by: .milliseconds(500))), "Evidence remains usable at the exact lease boundary")
		#expect(!boundary.permits(boundaryToken, at: now.advanced(by: .nanoseconds(500_000_001))), "One nanosecond beyond the lease expires evidence")
		#expect(!boundary.permits(boundaryToken, at: now.advanced(by: .nanoseconds(-1))), "Evidence cannot be used before its capture time")
		let gapBoundary = now.advanced(by: .milliseconds(240))
		let atGapAccepted = boundary.record(usable: true, capturedAt: gapBoundary)
		#expect(atGapAccepted, "Ordered delivery at the maximum gap is accepted")
		#expect(boundary.revision == boundaryToken, "Exact maximum gap preserves continuity")
		#expect(boundary.permits(boundaryToken, at: gapBoundary), "Original revision remains valid across an exact maximum gap")
		let duplicateAccepted = boundary.record(usable: true, capturedAt: gapBoundary)
		#expect(!duplicateAccepted, "Duplicate delivery timestamps are rejected")
		#expect(!boundary.permits(boundary.revision, at: gapBoundary), "Duplicate delivery clears usable evidence even for the new revision")
		let recoveryTime = now.advanced(by: .milliseconds(241))
		boundary.record(usable: true, capturedAt: recoveryTime)
		let recoveryToken = boundary.revision
		#expect(boundary.permits(recoveryToken, at: recoveryTime), "New delivery can recover after a duplicate")
		#expect(!boundary.permits(boundaryToken, at: recoveryTime), "Duplicate recovery never revives an earlier proof")
		boundary.record(usable: true, capturedAt: now.advanced(by: .milliseconds(481)))
		#expect(boundary.revision == recoveryToken, "Recovered stream retains the exact gap boundary")
		let excessiveGap = now.advanced(by: .nanoseconds(721_000_001))
		boundary.record(usable: true, capturedAt: excessiveGap)
		#expect(!boundary.permits(recoveryToken, at: excessiveGap), "One nanosecond over the gap invalidates an in-flight proof")
		#expect(boundary.permits(boundary.revision, at: excessiveGap), "Post-gap evidence can start only a new proof")
	}

	@Test func frameQualityRejectionsAndFloors() throws {
		#expect(FrameQuality.rejection(try makeSample()) == nil, "Normal fixture accepted")

		for quality: Float in [.nan, .infinity, -.infinity, -0.1, 1.1] {
			#expect(FrameQuality.rejection(try makeSample(quality: quality)) == .invalidMeasurements, "Malformed quality denied")
		}

		for value: Double in [.nan, .infinity, -.infinity] {
			let yawSample = try makeSample(pose: FacePose(yaw: value, pitch: 0, roll: 0))
			let pitchSample = try makeSample(pose: FacePose(yaw: 0, pitch: value, roll: 0))
			let rollSample = try makeSample(pose: FacePose(yaw: 0, pitch: 0, roll: value))
			#expect(FrameQuality.rejection(yawSample) != .invalidMeasurements)
			#expect(FrameQuality.rejection(pitchSample) != .invalidMeasurements)
			#expect(FrameQuality.rejection(rollSample) != .invalidMeasurements)
		}

		for bounds in [
			CGRect(x: -0.1, y: 0.2, width: 0.3, height: 0.3),
			CGRect(x: 0.2, y: 0.2, width: 0, height: 0.3),
			CGRect(x: 0.2, y: 0.2, width: 0.3, height: 2),
			CGRect(x: CGFloat.nan, y: 0.2, width: 0.3, height: 0.3),
		] {
			#expect(FrameQuality.rejection(try makeSample(boundingBox: bounds)) == .invalidMeasurements, "Invalid geometry denied")
		}

		#expect(FrameQuality.rejection(try makeSample(quality: 0, hasQualityMeasurement: true)) == .tooBlurred)
		#expect(FrameQuality.rejection(try makeSample(quality: 0, hasQualityMeasurement: false)) == nil)
		#expect(FrameQuality.rejection(try makeSample(quality: 0.09, hasQualityMeasurement: true)) == .tooBlurred)

		#expect(
			FrameQuality.rejection(try makeSample(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.13), quality: 0.7)) == .tooSmall
		)
		#expect(
			FrameQuality.rejection(try makeSample(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.15), quality: 0.7)) == nil
		)
	}
}
