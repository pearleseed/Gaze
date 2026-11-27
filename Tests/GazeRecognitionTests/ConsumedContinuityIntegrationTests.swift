import Foundation
import GazeCamera
import GazeRecognition
import Testing

@Suite("Consumed vs Delivered Continuity Integration")
struct ConsumedContinuityIntegrationTests {
	@Test func deliveredContinuityPacingAndConsumedGapBoundaries() {
		#expect(CameraEvidenceContinuity.maximumGap == .milliseconds(240))
		#expect(CameraFrameLease.maximumAge == .milliseconds(500))

		let start = ContinuousClock.now
		var delivered = CameraEvidenceContinuity()
		let d0 = delivered.record(usable: true, capturedAt: start)
		#expect(d0)
		let streamRevision = delivered.revision
		for frame in 1...8 {
			let ok = delivered.record(usable: true, capturedAt: start.advanced(by: .milliseconds(frame * 33)))
			#expect(ok)
		}
		#expect(delivered.revision == streamRevision)

		var consumed = RecognitionFrameGate(now: start)
		let c1 = consumed.observe(id: 1, capturedAt: start, now: start)
		#expect(c1 == .fresh(continuous: false))
		let second = start.advanced(by: .milliseconds(280))
		let secondCapture = start.advanced(by: .milliseconds(264))
		let c2 = consumed.observe(id: 9, capturedAt: secondCapture, now: second)
		#expect(c2 == .fresh(continuous: false))
		#expect(delivered.permits(streamRevision, at: second))
		for frame in 9...20 {
			let ok = delivered.record(usable: true, capturedAt: start.advanced(by: .milliseconds(frame * 33)))
			#expect(ok)
		}
		#expect(delivered.revision == streamRevision)

		// Pacing: slow evaluation must not add another fixed sleep.
		let evaluatedAt = start.advanced(by: .milliseconds(220))
		#expect(RecognitionScanPacing.delay(since: start, now: evaluatedAt) == .zero)
		#expect(
			RecognitionScanPacing.delay(since: start, now: start.advanced(by: .milliseconds(5)))
				== RecognitionScanPacing.minimumPollInterval - .milliseconds(5)
		)

		var paced = RecognitionFrameGate(now: start)
		_ = paced.observe(id: 1, capturedAt: start, now: start)
		let pacedCapture = start.advanced(by: .milliseconds(198))
		let pacedResult = paced.observe(id: 7, capturedAt: pacedCapture, now: evaluatedAt)
		#expect(pacedResult == .fresh(continuous: true))
		#expect(RecognitionScanPacing.delay(since: start, now: start) == RecognitionScanPacing.minimumPollInterval)

		// Consumed-side gap boundary.
		var exact = RecognitionFrameGate(now: start)
		let e1 = exact.observe(id: 1, capturedAt: start, now: start)
		#expect(e1 == .fresh(continuous: false))
		let atGap = start.advanced(by: CameraEvidenceContinuity.maximumGap)
		let e2 = exact.observe(id: 2, capturedAt: atGap, now: atGap)
		#expect(e2 == .fresh(continuous: true))

		var over = RecognitionFrameGate(now: start)
		let o1 = over.observe(id: 1, capturedAt: start, now: start)
		#expect(o1 == .fresh(continuous: false))
		let pastGap = start.advanced(by: .milliseconds(240)).advanced(by: .nanoseconds(1))
		let o2 = over.observe(id: 2, capturedAt: pastGap, now: pastGap)
		#expect(o2 == .fresh(continuous: false))

		// Fresh-but-gapped vs stale.
		var gapped = RecognitionFrameGate(now: start)
		let g1 = gapped.observe(id: 1, capturedAt: start, now: start)
		#expect(g1 == .fresh(continuous: false))
		let gappedAt = start.advanced(by: .milliseconds(300))
		let g2 = gapped.observe(id: 2, capturedAt: gappedAt, now: gappedAt)
		#expect(g2 == .fresh(continuous: false))

		var stale = RecognitionFrameGate(now: start)
		let s1 = stale.observe(id: 1, capturedAt: start, now: start)
		#expect(s1 == .fresh(continuous: false))
		let staleCapture = start.advanced(by: .milliseconds(100))
		let staleNow = start.advanced(by: .milliseconds(700))
		let s2 = stale.observe(id: 2, capturedAt: staleCapture, now: staleNow)
		#expect(s2 == .waiting)
	}
}
