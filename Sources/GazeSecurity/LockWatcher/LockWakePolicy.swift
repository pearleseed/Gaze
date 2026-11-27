import Foundation

/// Pure wake-settlement, display-sleep, and screen-saver reconciliation policies
/// for `LockWatcher`, kept side-effect free so sleep/wake races can be tested
/// deterministically without hardware or sleep cycles.
package enum LockWakePolicy {

	/// Debounce window between duplicate wake notifications (`didWake` and `screensDidWake`).
	package static let wakeDebounce: Duration = .seconds(3)

	/// Settle time after a normal wake (Apple → Sleep, keyboard, mouse, or desktop wake)
	/// before taking `LockScreenInputSnapshot`. Runs concurrently with camera startup so it
	/// adds no latency to unlock while absorbing wake clicks and key releases.
	package static let wakeSettle: Duration = .milliseconds(650)

	/// Shorter settle when the MacBook lid physically transitioned from closed to open
	/// with no keyboard or pointer wake input.
	package static let lidOpenSettle: Duration = .milliseconds(150)

	/// Minimum age for a cached `screenSaverRunning` flag before a missing
	/// `ScreenSaver.Engine` process is treated as a missed `didstop` notification.
	package static let screenSaverGrace: Duration = .milliseconds(1500)

	/// Bounded probe schedule when a wake notification arrives slightly before
	/// displays finish powering on or `CGSSessionScreenIsLocked` updates.
	package static let wakeProbeIntervals: [Duration] = [
		.milliseconds(150),
		.milliseconds(200),
		.milliseconds(300),
		.milliseconds(400),
		.milliseconds(500),
		.milliseconds(700),
		.milliseconds(1000),
	]

	/// Displays are asleep only when every online display is asleep (or none are online).
	/// On dual-display Macs where an external main display wakes slowly while the built-in
	/// display is already awake, checking only `CGMainDisplayID()` falsely reports asleep.
	package static func allDisplaysAsleep(displaySleepStates: [Bool]) -> Bool {
		guard !displaySleepStates.isEmpty else { return true }
		return displaySleepStates.allSatisfy { $0 }
	}

	/// Chooses the input settle duration after waking to a locked screen.
	///
	/// Only uses `lidOpenSettle` when the clamshell was closed at sleep, is now open,
	/// and no recent keyboard or pointer input occurred. Any Apple-menu Sleep with an
	/// open lid, desktop wake, or HID wake keeps the full `wakeSettle`.
	package static func settleDuration(
		clamshellWasClosed: Bool,
		clamshellIsClosed: Bool,
		secondsSinceKeyDown: TimeInterval,
		secondsSinceLeftClick: TimeInterval,
		secondsSinceRightClick: TimeInterval,
		secondsSinceMouseMove: TimeInterval
	) -> (duration: Duration, isLidOpen: Bool) {
		let quietWindow: TimeInterval = 1.5
		let noRecentInput =
			secondsSinceKeyDown > quietWindow
			&& secondsSinceLeftClick > quietWindow
			&& secondsSinceRightClick > quietWindow
			&& secondsSinceMouseMove > quietWindow
		if clamshellWasClosed && !clamshellIsClosed && noRecentInput {
			return (lidOpenSettle, true)
		}
		return (wakeSettle, false)
	}

	/// Whether a duplicate wake notification should be suppressed.
	///
	/// Suppresses duplicate notifications while a scan attempt is already running or
	/// immediately after a wake that produced frames/completed. Never suppresses a
	/// follow-up `didWake` notification when no attempt is running and the earlier
	/// `screensDidWake` failed before receiving frames.
	package static func shouldDebounceWake(
		lastWakeAt: ContinuousClock.Instant?,
		now: ContinuousClock.Instant,
		attemptActive: Bool,
		lastAttemptFailedCamera: Bool
	) -> Bool {
		if attemptActive { return true }
		guard !lastAttemptFailedCamera, let lastWakeAt, now >= lastWakeAt else { return false }
		return lastWakeAt.duration(to: now) < wakeDebounce
	}

	/// Reconciles the cached `screenSaverRunning` flag against live process state so
	/// a missed `com.apple.screensaver.didstop` during Sleep cannot permanently disable Gaze.
	package static func reconciledScreenSaverRunning(
		cachedRunning: Bool,
		processRunning: Bool,
		startedAt: ContinuousClock.Instant?,
		now: ContinuousClock.Instant
	) -> Bool {
		if processRunning { return true }
		guard cachedRunning else { return false }
		// Keep a freshly-posted didstart alive briefly while ScreenSaverEngine launches.
		if let startedAt, now >= startedAt, startedAt.duration(to: now) < screenSaverGrace {
			return true
		}
		return false
	}
}
