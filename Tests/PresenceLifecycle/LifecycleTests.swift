import Foundation

private enum TestError: Error { case failed(String) }

/// Synthetic lifecycle tests for walk-away locking policy and legacy backend cleanup.
///
/// Exercises the real production `UnlockExecutionPolicy`, `UnlockBackendKind`,
/// and `Preferences`: walk-away locking must be an opt-in available under the
/// normal policy independently of the unlock backend and password replay, and
/// never under scan-only, UI review, or any other prohibited launch policy.
/// Also verifies that removed `--browser-only` flags map safely to `.normal`
/// and legacy `"authPlugin"` `UserDefaults` values fall back safely to `.none`.
/// No camera is opened, no production preferences are written, no enrollment or
/// credentials are read, and `ScreenLock` is never touched. Structural lifecycle
/// behaviour (no duplicate starts, stop/clear on disable, startup ordering) is
/// covered by `test-wiring.sh`, which asserts on the production `AppServices` source.
@main
@MainActor
enum PresenceLifecycleTests {
	static var checks = 0
	static func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
		guard condition() else { throw TestError.failed(name) }
		checks += 1
		print("PASS \(name)")
	}

	static func main() throws {
		// Normal operation permits opt-in automatic locking. The property
		// takes no backend or replay inputs by construction — locking needs
		// neither password storage nor replay.
		try expect(UnlockExecutionPolicy.normal.permitsAutomaticLocking, "normal permits opt-in walk-away locking")

		// Every prohibited launch policy refuses it.
		try expect(!UnlockExecutionPolicy.scanOnly.permitsAutomaticLocking, "scan-only never starts the presence watcher")
		try expect(!UnlockExecutionPolicy.uiReview.permitsAutomaticLocking, "UI review never starts the presence watcher")

		// Launch-flag parsing lands on a prohibited policy, so a flagged run
		// can never arm walk-away locking whatever the setting says.
		try expect(!UnlockExecutionPolicy(arguments: ["--scan-only"]).permitsAutomaticLocking, "--scan-only run cannot lock")
		try expect(!UnlockExecutionPolicy(arguments: ["--ui-review"]).permitsAutomaticLocking, "--ui-review run cannot lock")
		try expect(UnlockExecutionPolicy(arguments: []) == .normal, "unflagged run resolves to normal")
		try expect(UnlockExecutionPolicy(arguments: []).permitsAutomaticLocking, "unflagged run permits opt-in locking")

		// Removed --browser-only flag no longer selects a separate policy.
		try expect(UnlockExecutionPolicy(arguments: ["--browser-only"]) == .normal, "removed --browser-only flag resolves to normal")
		try expect(UnlockExecutionPolicy(arguments: ["--browser-only"]).permitsAutomaticLocking, "removed --browser-only flag does not disable normal policy")

		// Admin prompt approval is permitted in normal and scan-only modes, refused in UI review.
		for replay in [false, true] {
			try expect(UnlockExecutionPolicy.normal.permitsAdminPromptApproval(passwordReplayEnabled: replay), "normal permits admin prompt approval (replay=\(replay))")
			try expect(UnlockExecutionPolicy.scanOnly.permitsAdminPromptApproval(passwordReplayEnabled: replay), "scan-only permits admin prompt approval (replay=\(replay))")
			try expect(!UnlockExecutionPolicy.uiReview.permitsAdminPromptApproval(passwordReplayEnabled: replay), "UI review refuses admin prompt approval (replay=\(replay))")
		}

		// Scan-only has precedence over UI review, regardless of argument order.
		try expect(!UnlockExecutionPolicy(arguments: ["--scan-only", "--ui-review"]).permitsAutomaticLocking, "diagnostic flag combination stays prohibited")

		// Legacy authPlugin backend is removed and unrecognized UserDefaults values fall back safely to .none.
		try expect(UnlockBackendKind(rawValue: "authPlugin") == nil, "authPlugin backend case is removed")
		try expect(UnlockBackendKind.allCases == [.none, .keystroke], "UnlockBackendKind exposes only none and keystroke")
		try expect(UnlockBackendKind.selectableCases == [.none, .keystroke], "UnlockBackendKind.selectableCases matches none and keystroke")

		let suite = "com.gazeunlock.PresenceLifecycleTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }

		try expect(Preferences(defaults: defaults).unlockBackend == .none, "unset unlockBackend defaults to .none")
		defaults.set("authPlugin", forKey: "unlockBackend")
		try expect(Preferences(defaults: defaults).unlockBackend == .none, "legacy authPlugin raw value in UserDefaults falls back safely to .none")
		defaults.set("unknownBackend", forKey: "unlockBackend")
		try expect(Preferences(defaults: defaults).unlockBackend == .none, "unknown unlockBackend raw value in UserDefaults falls back safely to .none")
		defaults.set("keystroke", forKey: "unlockBackend")
		try expect(Preferences(defaults: defaults).unlockBackend == .keystroke, "keystroke raw value in UserDefaults decodes to .keystroke")
		defaults.set("none", forKey: "unlockBackend")
		try expect(Preferences(defaults: defaults).unlockBackend == .none, "none raw value in UserDefaults decodes to .none")

		print("Lifecycle policy checks passed: \(checks)")
	}
}
