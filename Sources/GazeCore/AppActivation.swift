import AppKit

/// Brings the app forward when it shows a window.
///
/// Gaze runs as an accessory app so it owns a menu bar item rather than a Dock tile.
/// The cost is that its windows open behind whatever the user was doing, and — worse —
/// system prompts it raises, like Touch ID, can't come to the front either. Both are
/// fixed by switching to a regular app for as long as a window is on screen.
@MainActor
package enum AppActivation {
	package static var openSettings: (() -> Void)?

	/// True when launchd started us rather than the user.
	///
	/// A background launch must never take focus. Pairing an unconditional `activate()`
	/// with a `KeepAlive` LaunchAgent produced a process that grabbed focus every few
	/// seconds and was resurrected each time it exited — which makes the machine
	/// effectively unusable. Focus is only ever appropriate when the user asked for a
	/// window.
	package static var isBackgroundLaunch: Bool {
		CommandLine.arguments.contains("--agent")
	}

	package static func bringToFront(userInitiated: Bool = false) {
		guard userInitiated || !isBackgroundLaunch else { return }
		NSApp.setActivationPolicy(.regular)
		NSApp.activate()
		raiseVisibleWindows()
		// Callers invoke this *before* `openWindow`, so the window being asked for does not
		// exist yet and the pass above cannot raise it. Nothing raised it afterwards either:
		// Settings opened from the menu bar appeared behind whatever app was in front.
		// Activation right after an activation-policy change is also unreliable for an app
		// that was an accessory a moment ago. So the window is raised again once it has had
		// time to appear, and activation is forced if the first attempt lost.
		let generation = raiseGeneration &+ 1
		raiseGeneration = generation
		for delay in [0.05, 0.15, 0.4] {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
				MainActor.assumeIsolated {
					// A newer request supersedes this one, and the user may have closed
					// the window or moved on meanwhile.
					guard raiseGeneration == generation else { return }
					if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
					raiseVisibleWindows()
				}
			}
		}
	}

	private static var raiseGeneration = 0

	/// Only windows already on screen, and only the key-capable ones.
	///
	/// SwiftUI does not destroy a `Window` scene when it is dismissed — it orders it out
	/// and keeps it — so `NSApp.windows` holds every window the app has ever shown.
	/// Raising all of them meant opening any one window dragged every previously-closed
	/// window back up with it: open Settings and the setup flow you finished last week
	/// reappears on top of it.
	///
	/// This filter was removed once already, on the theory that the loop is what presents
	/// a freshly-created window and so must not skip invisible ones. That was wrong twice
	/// over: SwiftUI's `openWindow` and `.defaultLaunchBehavior(.presented)` do the
	/// presenting, this loop only wins a race against them; and the evidence for the
	/// theory was a test harness that had stopped activating the app before listing
	/// windows, so it reported every window as missing whatever the code did.
	private static func raiseVisibleWindows() {
		let windows = NSApp.windows.filter { $0.canBecomeKey && $0.isVisible }
		for window in windows { window.orderFrontRegardless() }
		// Key goes to the one that was most recently in front, not to whichever is last.
		if let front = windows.min(by: { $0.orderedIndex < $1.orderedIndex }), !front.isKeyWindow {
			front.makeKey()
		}
	}

	/// Drops back to a menu bar-only app once no windows remain.
	///
	/// Deferred, and deliberately.
	///
	/// unxnown reported the Dock icon appearing and then, on clicking it, "shows something
	/// then vanishes instantly". This was why. Windows close and open in the same runloop
	/// turn — the enrolment window dismisses itself at launch, Settings opens from the menu
	/// while another window is still tearing down — and `onDisappear` fires in the gap where
	/// the closing window is gone and the opening one is not yet on screen. Seeing no
	/// windows, this dropped the app to `.accessory`, and switching activation policy while
	/// a window is coming up orders it straight back out.
	///
	/// Waiting a beat and asking again means the question is answered once the runloop has
	/// settled, rather than in the middle of a handover.
	package static func returnToBackgroundIfIdle() {
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
			MainActor.assumeIsolated {
				// `canBecomeKey` excludes the lock screen panel, which must never hold the
				// app in `.regular` — it is on screen for most of the time the Mac is locked.
				let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
				guard !hasWindow else { return }
				NSApp.setActivationPolicy(.accessory)
			}
		}
	}
}
