import Foundation
import os

/// Opt-in per-phase startup timing. Enabled only with `--startup-diagnostics`.
///
/// Measures startup phases without reordering or deferring any startup work.
/// Logs only fixed phase labels and numeric durations — never names, paths,
/// enrollment contents, identifiers, passwords, or camera data. Never logs on
/// repeating timers; startup only.
@MainActor
enum StartupTiming {
	private static let logger = Logger(subsystem: "com.gazeunlock.Gaze", category: "Startup")

	static var isEnabled: Bool {
		CommandLine.arguments.contains("--startup-diagnostics")
	}

	static func start() -> TimeInterval? {
		isEnabled ? ProcessInfo.processInfo.systemUptime : nil
	}

	static func finish(label: String, start: TimeInterval?) {
		guard let start, isEnabled else { return }
		let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
		logger.notice("\(label, privacy: .public): \(Int(elapsedMs), privacy: .public)ms")
	}

	/// Runs `operation` directly with no timing or logging when disabled; otherwise
	/// logs the elapsed milliseconds under the fixed `label` after completion.
	static func measure<T>(label: String, operation: () -> T) -> T {
		guard isEnabled else { return operation() }
		let start = ProcessInfo.processInfo.systemUptime
		let result = operation()
		let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
		logger.notice("\(label, privacy: .public): \(Int(elapsedMs), privacy: .public)ms")
		return result
	}
}
