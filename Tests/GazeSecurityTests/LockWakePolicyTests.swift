import Foundation
import GazeSecurity
import Testing

@Suite("Lock Wake Policy — Sleep/Wake Settlement, Multi-Display & Screen Saver")
struct LockWakePolicyTests {
	@Test func displaysAreAsleepOnlyWhenEveryOnlineDisplayIsAsleep() {
		#expect(LockWakePolicy.allDisplaysAsleep(displaySleepStates: []))
		#expect(LockWakePolicy.allDisplaysAsleep(displaySleepStates: [true]))
		#expect(LockWakePolicy.allDisplaysAsleep(displaySleepStates: [true, true]))
		// External main display still negotiating while built-in display is awake.
		#expect(!LockWakePolicy.allDisplaysAsleep(displaySleepStates: [true, false]))
		#expect(!LockWakePolicy.allDisplaysAsleep(displaySleepStates: [false, true]))
		#expect(!LockWakePolicy.allDisplaysAsleep(displaySleepStates: [false, false]))
	}

	@Test func settleDurationUsesLidOpenOnlyForGenuineQuietClamshellOpen() {
		let lidOpen = LockWakePolicy.settleDuration(
			clamshellWasClosed: true,
			clamshellIsClosed: false,
			secondsSinceKeyDown: 10,
			secondsSinceLeftClick: 10,
			secondsSinceRightClick: 10,
			secondsSinceMouseMove: 10
		)
		#expect(lidOpen.duration == LockWakePolicy.lidOpenSettle && lidOpen.isLidOpen)

		// Apple -> Sleep with lid open must keep full wakeSettle even when HID is quiet.
		let openLidSleep = LockWakePolicy.settleDuration(
			clamshellWasClosed: false,
			clamshellIsClosed: false,
			secondsSinceKeyDown: 60,
			secondsSinceLeftClick: 60,
			secondsSinceRightClick: 60,
			secondsSinceMouseMove: 60
		)
		#expect(openLidSleep.duration == LockWakePolicy.wakeSettle && !openLidSleep.isLidOpen)

		// Clamshell mode with external display (still closed) keeps full wakeSettle.
		let closedClamshell = LockWakePolicy.settleDuration(
			clamshellWasClosed: true,
			clamshellIsClosed: true,
			secondsSinceKeyDown: 60,
			secondsSinceLeftClick: 60,
			secondsSinceRightClick: 60,
			secondsSinceMouseMove: 60
		)
		#expect(closedClamshell.duration == LockWakePolicy.wakeSettle && !closedClamshell.isLidOpen)

		// Any recent HID event (key, click, right-click, mouse move) keeps full wakeSettle.
		for (key, left, right, move) in [
			(0.2, 10.0, 10.0, 10.0),
			(10.0, 0.2, 10.0, 10.0),
			(10.0, 10.0, 0.2, 10.0),
			(10.0, 10.0, 10.0, 0.2),
			(1.5, 10.0, 10.0, 10.0),
		] {
			let result = LockWakePolicy.settleDuration(
				clamshellWasClosed: true,
				clamshellIsClosed: false,
				secondsSinceKeyDown: key,
				secondsSinceLeftClick: left,
				secondsSinceRightClick: right,
				secondsSinceMouseMove: move
			)
			#expect(result.duration == LockWakePolicy.wakeSettle && !result.isLidOpen)
		}
	}

	@Test func wakeDebounceSuppressesDuplicatesButAllowsRecoveryAfterCameraFailure() {
		let start = ContinuousClock.now

		// Active attempt always suppresses duplicate wake events.
		#expect(LockWakePolicy.shouldDebounceWake(
			lastWakeAt: nil, now: start, attemptActive: true, lastAttemptFailedCamera: true
		))

		// First wake is allowed.
		#expect(!LockWakePolicy.shouldDebounceWake(
			lastWakeAt: nil, now: start, attemptActive: false, lastAttemptFailedCamera: false
		))

		// Duplicate wake within 3s when previous attempt did not fail camera is suppressed.
		#expect(LockWakePolicy.shouldDebounceWake(
			lastWakeAt: start,
			now: start.advanced(by: .milliseconds(650)),
			attemptActive: false,
			lastAttemptFailedCamera: false
		))

		// Once debounce window elapses, a new wake is allowed.
		#expect(!LockWakePolicy.shouldDebounceWake(
			lastWakeAt: start,
			now: start.advanced(by: .seconds(3)),
			attemptActive: false,
			lastAttemptFailedCamera: false
		))

		// Follow-up didWake right after a screensDidWake camera failure MUST NOT be dropped.
		#expect(!LockWakePolicy.shouldDebounceWake(
			lastWakeAt: start,
			now: start.advanced(by: .milliseconds(650)),
			attemptActive: false,
			lastAttemptFailedCamera: true
		))

		// Clock reversal fails open rather than wedging debounce.
		#expect(!LockWakePolicy.shouldDebounceWake(
			lastWakeAt: start.advanced(by: .seconds(5)),
			now: start,
			attemptActive: false,
			lastAttemptFailedCamera: false
		))
	}

	@Test func screenSaverReconciliationClearsStaleFlagAfterMissedDidStop() {
		let start = ContinuousClock.now

		// Live ScreenSaverEngine process always counts as running.
		#expect(LockWakePolicy.reconciledScreenSaverRunning(
			cachedRunning: false, processRunning: true, startedAt: nil, now: start
		))

		// Idle state stays false.
		#expect(!LockWakePolicy.reconciledScreenSaverRunning(
			cachedRunning: false, processRunning: false, startedAt: nil, now: start
		))

		// Freshly-started screen saver gets a brief launch grace before process appears.
		#expect(LockWakePolicy.reconciledScreenSaverRunning(
			cachedRunning: true,
			processRunning: false,
			startedAt: start,
			now: start.advanced(by: .milliseconds(500))
		))

		// Stale cached flag after missed didstop across Sleep is cleared once grace expires.
		#expect(!LockWakePolicy.reconciledScreenSaverRunning(
			cachedRunning: true,
			processRunning: false,
			startedAt: start,
			now: start.advanced(by: .milliseconds(1500))
		))
		#expect(!LockWakePolicy.reconciledScreenSaverRunning(
			cachedRunning: true,
			processRunning: false,
			startedAt: nil,
			now: start
		))
	}

	@Test func wakeProbeScheduleIsBounded() {
		#expect(!LockWakePolicy.wakeProbeIntervals.isEmpty)
		var total = Duration.zero
		for interval in LockWakePolicy.wakeProbeIntervals {
			#expect(interval > .zero)
			total += interval
		}
		#expect(total >= .seconds(2) && total <= .seconds(5))
	}
}
