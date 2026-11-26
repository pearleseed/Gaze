import Foundation
import GazeApp
import GazeCore
import GazeSecurity
import Testing

@Suite("Idle Efficiency & UI Readiness")
@MainActor
struct IdleEfficiencyTests {
	private func makeIsolatedPreferences() -> Preferences {
		let suiteName = "com.pearleseed.gaze.tests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return Preferences(defaults: defaults)
	}

	// MARK: - MenuBarStatusModel

	@Test func menuBarStatusEvaluatesBackendReadinessOnceAcrossBackendStates() {
		let cases: [(BackendReadiness, String, Bool)] = [
			(.ready, "Gaze is ready", false),
			(.needsSetup("Missing permission"), "Unlock needs attention — open Settings", true),
			(.unavailable("No model"), "Unlock needs attention — open Settings", true),
		]

		for (readinessResult, expectedTitle, expectedOpensSettings) in cases {
			var readinessCalls = 0
			let snapshot = MenuBarStatusModel.evaluate(
				executionPolicy: .normal,
				isLockedOut: false,
				isEnrolled: true,
				isPaused: false,
				pausedUntil: nil,
				cameraAuthorized: true,
				passwordReplayEnabled: true,
				unlockBackend: .keystroke,
				readiness: {
					readinessCalls += 1
					return readinessResult
				}
			)
			#expect(readinessCalls == 1)
			#expect(snapshot == MenuBarStatusSnapshot(title: expectedTitle, opensSettings: expectedOpensSettings))
		}
	}

	@Test func menuBarStatusShortCircuitsBeforeReadinessForEarlyStates() {
		let futurePause = Date().addingTimeInterval(600)

		var pausedCalls = 0
		let paused = MenuBarStatusModel.evaluate(
			executionPolicy: .normal,
			isLockedOut: false,
			isEnrolled: true,
			isPaused: true,
			pausedUntil: futurePause,
			cameraAuthorized: true,
			passwordReplayEnabled: true,
			unlockBackend: .keystroke,
			readiness: {
				pausedCalls += 1
				return .ready
			}
		)
		#expect(pausedCalls == 0)
		#expect(paused.opensSettings == false)
		#expect(paused.title.hasPrefix("Paused until "))

		var lockedOutCalls = 0
		let lockedOut = MenuBarStatusModel.evaluate(
			executionPolicy: .normal,
			isLockedOut: true,
			isEnrolled: true,
			isPaused: false,
			pausedUntil: nil,
			cameraAuthorized: true,
			passwordReplayEnabled: true,
			unlockBackend: .keystroke,
			readiness: {
				lockedOutCalls += 1
				return .ready
			}
		)
		#expect(lockedOutCalls == 0)
		#expect(lockedOut == MenuBarStatusSnapshot(title: "Locked out — password required", opensSettings: true))

		var unenrolledCalls = 0
		let unenrolled = MenuBarStatusModel.evaluate(
			executionPolicy: .normal,
			isLockedOut: false,
			isEnrolled: false,
			isPaused: false,
			pausedUntil: nil,
			cameraAuthorized: true,
			passwordReplayEnabled: true,
			unlockBackend: .keystroke,
			readiness: {
				unenrolledCalls += 1
				return .ready
			}
		)
		#expect(unenrolledCalls == 0)
		#expect(unenrolled == MenuBarStatusSnapshot(title: "No face enrolled", opensSettings: true))

		var policyCalls = 0
		let uiReview = MenuBarStatusModel.evaluate(
			executionPolicy: .uiReview,
			isLockedOut: false,
			isEnrolled: true,
			isPaused: false,
			pausedUntil: nil,
			cameraAuthorized: true,
			passwordReplayEnabled: true,
			unlockBackend: .keystroke,
			readiness: {
				policyCalls += 1
				return .ready
			}
		)
		#expect(policyCalls == 0)
		#expect(uiReview == MenuBarStatusSnapshot(title: "UI review — unlocking is off", opensSettings: false))

		let scanOnly = MenuBarStatusModel.evaluate(
			executionPolicy: .scanOnly,
			isLockedOut: false,
			isEnrolled: true,
			isPaused: false,
			pausedUntil: nil,
			cameraAuthorized: true,
			passwordReplayEnabled: true,
			unlockBackend: .keystroke,
			readiness: {
				policyCalls += 1
				return .ready
			}
		)
		#expect(policyCalls == 0)
		#expect(scanOnly == MenuBarStatusSnapshot(title: "Scan-only mode — unlocking is off", opensSettings: false))

		let noCamera = MenuBarStatusModel.evaluate(
			executionPolicy: .normal,
			isLockedOut: false,
			isEnrolled: true,
			isPaused: false,
			pausedUntil: nil,
			cameraAuthorized: false,
			passwordReplayEnabled: true,
			unlockBackend: .keystroke,
			readiness: {
				policyCalls += 1
				return .ready
			}
		)
		#expect(policyCalls == 0)
		#expect(noCamera == MenuBarStatusSnapshot(title: "Camera access needed", opensSettings: true))

		let replayOff = MenuBarStatusModel.evaluate(
			executionPolicy: .normal,
			isLockedOut: false,
			isEnrolled: true,
			isPaused: false,
			pausedUntil: nil,
			cameraAuthorized: true,
			passwordReplayEnabled: false,
			unlockBackend: .keystroke,
			readiness: {
				policyCalls += 1
				return .ready
			}
		)
		#expect(policyCalls == 0)
		#expect(replayOff == MenuBarStatusSnapshot(title: "Mac unlocking is off", opensSettings: true))

		let recognitionOnly = MenuBarStatusModel.evaluate(
			executionPolicy: .normal,
			isLockedOut: false,
			isEnrolled: true,
			isPaused: false,
			pausedUntil: nil,
			cameraAuthorized: true,
			passwordReplayEnabled: true,
			unlockBackend: .none,
			readiness: {
				policyCalls += 1
				return .ready
			}
		)
		#expect(policyCalls == 0)
		#expect(recognitionOnly == MenuBarStatusSnapshot(title: "Recognition only", opensSettings: false))
	}

	// MARK: - DesktopWallpaper Polling Tokens

	@Test func desktopWallpaperTokenCounterControlsFallbackPollingLifecycle() async {
		var refreshCount = 0
		let wallpaper = DesktopWallpaper(
			observeSystemEvents: false,
			pollInterval: .milliseconds(25),
			onRefresh: { refreshCount += 1 }
		)

		#expect(wallpaper.isFallbackPollingActive == false)
		#expect(refreshCount == 0)

		let token1 = wallpaper.acquirePollingToken()
		#expect(wallpaper.isFallbackPollingActive == true)
		#expect(refreshCount == 1)

		let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
		while refreshCount < 2 && ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(15))
		}
		#expect(refreshCount >= 2)

		let token2 = wallpaper.acquirePollingToken()
		#expect(wallpaper.isFallbackPollingActive == true)

		token1.invalidate()
		#expect(wallpaper.isFallbackPollingActive == true)

		token2.invalidate()
		#expect(wallpaper.isFallbackPollingActive == false)

		// Double invalidation must be a safe no-op.
		token2.invalidate()
		#expect(wallpaper.isFallbackPollingActive == false)

		let countAfterStop = refreshCount
		try? await Task.sleep(for: .milliseconds(90))
		#expect(refreshCount == countAfterStop)
	}

	@Test func desktopWallpaperTokenReleasesAutomaticallyOnDeinit() {
		var refreshCount = 0
		let wallpaper = DesktopWallpaper(
			observeSystemEvents: false,
			pollInterval: .seconds(2),
			onRefresh: { refreshCount += 1 }
		)

		#expect(wallpaper.isFallbackPollingActive == false)
		var token: DesktopWallpaper.WallpaperVisibilityToken? = wallpaper.acquirePollingToken()
		#expect(token != nil)
		#expect(wallpaper.isFallbackPollingActive == true)
		#expect(refreshCount == 1)

		token = nil
		#expect(wallpaper.isFallbackPollingActive == false)
	}

	// MARK: - AdminPromptApproval Zero Idle Wakeups

	@Test func adminPromptApprovalRunsTimerOnlyWhenEnabledAndUnpaused() {
		let preferences = makeIsolatedPreferences()
		preferences.approveAdminPrompts = false

		let service = AdminPromptApproval(
			preferences: preferences,
			isPasswordReplayEnabled: { true },
			executionPolicy: .normal
		)
		defer { service.stop() }

		service.start()
		#expect(service.isPollingActive == false)

		// Enabling preference arms polling immediately via notification.
		preferences.approveAdminPrompts = true
		#expect(service.isPollingActive == true)

		// Pausing disarms polling immediately (0 wakeups).
		preferences.pause(for: 3600)
		#expect(service.isPollingActive == false)

		// Resuming re-arms polling immediately.
		preferences.resume()
		#expect(service.isPollingActive == true)

		// Enabling while paused keeps polling inactive until resumed.
		preferences.pause(for: 3600)
		preferences.approveAdminPrompts = true
		#expect(service.isPollingActive == false)
		preferences.resume()
		#expect(service.isPollingActive == true)

		// Disabling disarms polling immediately.
		preferences.approveAdminPrompts = false
		#expect(service.isPollingActive == false)
	}

	@Test func adminPromptApprovalRearmsAutomaticallyWhenTimedPauseExpires() {
		let preferences = makeIsolatedPreferences()
		preferences.approveAdminPrompts = true

		let service = AdminPromptApproval(
			preferences: preferences,
			isPasswordReplayEnabled: { true },
			executionPolicy: .normal
		)
		defer { service.stop() }

		service.start()
		#expect(service.isPollingActive == true)

		preferences.pause(for: 0.08)
		#expect(service.isPollingActive == false)

		let deadline = Date().addingTimeInterval(0.6)
		while !service.isPollingActive && Date() < deadline {
			RunLoop.main.run(until: Date().addingTimeInterval(0.01))
		}
		#expect(service.isPollingActive == true)
	}

	@Test func adminPromptApprovalRespectsStopAndSecurityPolicies() {
		let preferences = makeIsolatedPreferences()
		preferences.approveAdminPrompts = true

		// Password replay off -> never polls.
		let replayDisabled = AdminPromptApproval(
			preferences: preferences,
			isPasswordReplayEnabled: { false },
			executionPolicy: .normal
		)
		defer { replayDisabled.stop() }
		replayDisabled.start()
		#expect(replayDisabled.isPollingActive == false)

		// UI review policy -> never polls.
		let uiReview = AdminPromptApproval(
			preferences: preferences,
			isPasswordReplayEnabled: { true },
			executionPolicy: .uiReview
		)
		defer { uiReview.stop() }
		uiReview.start()
		#expect(uiReview.isPollingActive == false)

		// Scan-only policy permits admin prompt approval when enabled and unpaused.
		let scanOnly = AdminPromptApproval(
			preferences: preferences,
			isPasswordReplayEnabled: { true },
			executionPolicy: .scanOnly
		)
		defer { scanOnly.stop() }
		scanOnly.start()
		#expect(scanOnly.isPollingActive == true)

		// Stopped service stays off even when preference flips.
		let stoppable = AdminPromptApproval(
			preferences: preferences,
			isPasswordReplayEnabled: { true },
			executionPolicy: .normal
		)
		stoppable.start()
		#expect(stoppable.isPollingActive == true)
		stoppable.stop()
		#expect(stoppable.isPollingActive == false)

		preferences.pause(for: 0.05)
		RunLoop.main.run(until: Date().addingTimeInterval(0.1))
		#expect(stoppable.isPollingActive == false)
	}

	// MARK: - SettingsView External Refresh Coalescing

	@Test func externalRefreshCoalescerSuppressesBurstsWithinWindowAndAllowsForcedOrExpiredRefreshes() {
		var coalescer = ExternalRefreshCoalescer(minimumInterval: .milliseconds(150))
		let t0 = ContinuousClock.now

		#expect(coalescer.shouldRefresh(now: t0) == true)
		#expect(coalescer.shouldRefresh(now: t0.advanced(by: .milliseconds(10))) == false)
		#expect(coalescer.shouldRefresh(now: t0.advanced(by: .milliseconds(149))) == false)
		#expect(coalescer.shouldRefresh(now: t0.advanced(by: .milliseconds(150))) == true)

		// Explicit post-action refresh overrides the coalesce window.
		#expect(coalescer.shouldRefresh(now: t0.advanced(by: .milliseconds(160)), force: true) == true)
		#expect(coalescer.shouldRefresh(now: t0.advanced(by: .milliseconds(200))) == false)

		// Disappear/reset clears the window.
		coalescer.reset()
		#expect(coalescer.shouldRefresh(now: t0.advanced(by: .milliseconds(205))) == true)
	}
}
