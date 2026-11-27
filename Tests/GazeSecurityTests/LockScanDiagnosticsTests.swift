import Foundation
import GazeSecurity
import Testing

@Suite("Lock Scan Diagnostics Isolation & Summaries")
@MainActor
struct LockScanDiagnosticsTests {
	@Test func staleIsolationOutcomesAndMovementDiagnostics() {
		let diagnostics = LockScanDiagnostics()
		let first = UUID()
		let second = UUID()

		#expect(diagnostics.outcome == nil)
		diagnostics.begin(first)
		#expect(diagnostics.outcome == .starting)
		diagnostics.record(.scanning, for: first)
		#expect(diagnostics.outcome == .scanning)

		diagnostics.begin(second)
		diagnostics.record(.submissionUnconfirmed, for: first)
		diagnostics.finishScanning(for: first)
		diagnostics.cancel(for: first)
		#expect(diagnostics.outcome == .starting)

		for outcome in LockScanDiagnostics.Outcome.allCases {
			diagnostics.record(outcome, for: second)
			#expect(!diagnostics.summary.isEmpty)
			#expect(!diagnostics.summary.contains(second.uuidString))
			diagnostics.finishScanning(for: second)
			#expect(diagnostics.outcome == (outcome.isScanning ? .cancelled : outcome))
		}

		diagnostics.record(.submissionPending, for: second)
		diagnostics.cancel(for: second)
		#expect(diagnostics.outcome == .cancelled)

		diagnostics.record(.firstFrameTimeout, for: second)
		diagnostics.cancel(for: second)
		#expect(diagnostics.outcome == .firstFrameTimeout)

		#expect(LockScanDiagnostics.Outcome.submissionStopped.message.contains("will not retry"))
		#expect(!LockScanDiagnostics.Outcome.submissionStopped.message.contains("No password was sent"))

		let movement = LockScanDiagnostics.MovementFailure(
			action: "Turn slightly left",
			returning: false,
			comparedIdentity: true,
			score: 0.405,
			threshold: 0.45,
			poseOffset: -0.2,
			poseTarget: 0.3,
			returnTolerance: 0.1
		)
		diagnostics.recordMovementFailure(movement, for: first)
		#expect(diagnostics.movementFailure == nil)

		diagnostics.recordMovementFailure(movement, for: second)
		#expect(diagnostics.summary.contains("0.405") && diagnostics.summary.contains("-0.20 rad"))

		diagnostics.record(.scanning, for: second)
		#expect(diagnostics.summary.contains("Last movement stopped"))

		diagnostics.recordMovementFailure(
			.init(
				action: "Turn slightly right",
				returning: true,
				comparedIdentity: false,
				score: 0,
				threshold: 0.45,
				poseOffset: nil,
				poseTarget: nil,
				returnTolerance: nil
			),
			for: second
		)
		#expect(
			diagnostics.summary.contains("returning to the starting pose")
				&& diagnostics.summary.contains("could not complete")
		)
		#expect(!diagnostics.summary.contains("was below") && !diagnostics.summary.contains("Movement from start"))

		diagnostics.begin(UUID())
		#expect(diagnostics.movementFailure == nil && !diagnostics.summary.contains("Last movement stopped"))
	}
}
