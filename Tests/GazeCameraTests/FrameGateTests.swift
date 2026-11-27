import CoreGraphics
import CoreVideo
import Foundation
import GazeCamera
import GazeRecognition
import Testing
import Vision

@Suite("Recognition Frame Gate, Rejection & Match Hold")
@MainActor
struct FrameGateTests {
	private func makeSample(quality: Float = 0.8, hasQualityMeasurement: Bool = true) throws -> FaceSample {
		var pixelBuffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
		)
		#expect(status == kCVReturnSuccess)
		let buffer = try #require(pixelBuffer)
		let box = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
		let face = VNFaceObservation(boundingBox: box)
		let request = VNDetectFaceLandmarksRequest()
		request.inputFaceObservations = [face]
		try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
		let landmarks = try #require(request.results?.first?.landmarks)
		return FaceSample(
			landmarks: landmarks,
			boundingBox: box,
			pose: .zero,
			quality: quality,
			hasQualityMeasurement: hasQualityMeasurement,
			pixelBuffer: buffer
		)
	}

	@Test func warmupStallRecoveryClockReversalAndAgeBoundaries() {
		let start = ContinuousClock.now
		var cold = RecognitionFrameGate(now: start)
		for milliseconds in [0, 500, 1_000, 1_500, 3_000, 4_000, 7_500] {
			let obs = cold.observe(id: 0, capturedAt: nil, now: start.advanced(by: .milliseconds(milliseconds)))
			#expect(obs == .waiting, "cold camera gets a bounded first-frame warmup at \(milliseconds)ms")
		}
		let expired = start.advanced(by: .seconds(8)).advanced(by: .nanoseconds(1))
		let expiredObs = cold.observe(id: 0, capturedAt: nil, now: expired)
		#expect(expiredObs == .stalled)
		let lateObs = cold.observe(id: 1, capturedAt: expired, now: expired)
		#expect(lateObs == .stalled)

		for delay in [1_500, 2_500, 4_000] {
			var recovering = RecognitionFrameGate(now: start)
			let arriving = start.advanced(by: .milliseconds(delay))
			let r0 = recovering.observe(id: 0, capturedAt: nil, now: start.advanced(by: .seconds(1)))
			#expect(r0 == .waiting)
			let r1 = recovering.observe(id: 1, capturedAt: arriving, now: arriving)
			#expect(r1 == .fresh(continuous: false))
			let next = arriving.advanced(by: .milliseconds(100))
			let r2 = recovering.observe(id: 2, capturedAt: next, now: next)
			#expect(r2 == .fresh(continuous: true))
			let r3 = recovering.observe(id: 2, capturedAt: next, now: next.advanced(by: .seconds(1)))
			#expect(r3 == .waiting)
			let stalled = next.advanced(by: .seconds(1)).advanced(by: .nanoseconds(1))
			let r4 = recovering.observe(id: 2, capturedAt: next, now: stalled)
			#expect(r4 == .stalled)
		}

		var invalid = RecognitionFrameGate(now: start)
		let twoSeconds = start.advanced(by: .seconds(2))
		let inv1 = invalid.observe(id: 1, capturedAt: start, now: twoSeconds)
		#expect(inv1 == .waiting)
		let inv2 = invalid.observe(id: 2, capturedAt: twoSeconds.advanced(by: .seconds(1)), now: twoSeconds)
		#expect(inv2 == .waiting)
		let inv3 = invalid.observe(id: 3, capturedAt: expired, now: expired)
		#expect(inv3 == .stalled)

		var delayedPoll = RecognitionFrameGate(now: start)
		let dp1 = delayedPoll.observe(id: 1, capturedAt: start, now: start)
		#expect(dp1 == .fresh(continuous: false))
		let dp2 = delayedPoll.observe(id: 2, capturedAt: twoSeconds, now: twoSeconds)
		#expect(dp2 == .stalled)

		var reversed = RecognitionFrameGate(now: start)
		let rev1 = reversed.observe(id: 1, capturedAt: start, now: start.advanced(by: .nanoseconds(-1)))
		#expect(rev1 == .stalled)
		let rev2 = reversed.observe(id: 2, capturedAt: start, now: start)
		#expect(rev2 == .stalled)

		var ageBoundary = RecognitionFrameGate(now: start)
		let halfSecond = start.advanced(by: CameraFrameLease.maximumAge)
		let ab1 = ageBoundary.observe(id: 1, capturedAt: start, now: halfSecond)
		#expect(ab1 == .fresh(continuous: false))
		var tooOld = RecognitionFrameGate(now: start)
		let to1 = tooOld.observe(id: 1, capturedAt: start, now: halfSecond.advanced(by: .nanoseconds(1)))
		#expect(to1 == .waiting)
	}

	@Test func rejectionHoldQualityContinuityAndMatchHold() throws {
		let start = ContinuousClock.now
		var rejection = RecognitionRejectionHold()
		for tick in 0...40 {
			let rejected = rejection.consume(capturedAt: start.advanced(by: .milliseconds(tick * 100)), required: .seconds(4))
			#expect(rejected == (tick == 40))
		}
		rejection.reset()
		let afterLongMatch = start.advanced(by: .seconds(20))
		let afterMatch = rejection.consume(capturedAt: afterLongMatch, required: .seconds(4))
		#expect(!afterMatch)
		for tick in 1...100 {
			rejection.reset()
			let stepped = rejection.consume(capturedAt: afterLongMatch.advanced(by: .milliseconds(tick * 100)), required: .seconds(4))
			#expect(!stepped)
		}
		var discontinuous = RecognitionRejectionHold()
		for tick in 0...20 {
			let gapped = discontinuous.consume(capturedAt: start.advanced(by: .milliseconds(tick * 300)), required: .seconds(4))
			#expect(!gapped)
		}
		let outOfOrder = discontinuous.consume(capturedAt: start, required: .seconds(4))
		#expect(!outOfOrder)
		let duplicate = discontinuous.consume(capturedAt: start, required: .seconds(4))
		#expect(!duplicate)
		let zeroReq = discontinuous.consume(capturedAt: start, required: .zero)
		#expect(!zeroReq)

		let next = start.advanced(by: .milliseconds(100))
		var evidence = CameraEvidenceContinuity()
		let r1 = evidence.record(usable: FrameQuality.isUsable(try makeSample()), capturedAt: start)
		#expect(r1)
		let revision = evidence.revision
		#expect(evidence.permits(revision, at: next))
		let r2 = evidence.record(usable: FrameQuality.isUsable(try makeSample(quality: 0, hasQualityMeasurement: true)), capturedAt: next)
		#expect(r2)
		#expect(!evidence.permits(revision, at: next))
		let recovery = next.advanced(by: .milliseconds(100))
		let r3 = evidence.record(usable: FrameQuality.isUsable(try makeSample(quality: 0, hasQualityMeasurement: false)), capturedAt: recovery)
		#expect(r3)
		#expect(evidence.permits(evidence.revision, at: recovery))
		let r4 = evidence.record(usable: true, capturedAt: start)
		#expect(!r4)
		#expect(!evidence.permits(evidence.revision, at: recovery))
		evidence.invalidate()
		#expect(!evidence.permits(evidence.revision, at: recovery))

		var hold = RecognitionMatchHold()
		let owner = UUID()
		let h1 = hold.consume(faceID: owner, now: start, required: .milliseconds(300))
		#expect(!h1)
		let h2 = hold.consume(faceID: owner, now: recovery.advanced(by: .milliseconds(100)), required: .milliseconds(300))
		#expect(h2)
		let h3 = hold.consume(faceID: UUID(), now: recovery, required: .milliseconds(300))
		#expect(!h3)
		hold.reset()
		#expect(hold.faceID == nil)
	}
}
