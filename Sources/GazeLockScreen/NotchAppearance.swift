import SwiftUI

/// The island's measurements, in one place.
///
/// Shared with the controller because the window has to be built big enough to hold what the
/// view will draw, and the two disagreeing is how the shadow ended up clipped against the
/// window's edge.
package enum IslandMetrics {
	/// Between the housing and the island, so it reads as a separate object rather than as
	/// the panel with its corners filed off.
	package static let gap: CGFloat = 8

	/// Empty space below the island for its shadow to fall into.
	package static let shadowRoom: CGFloat = 24

	/// The window's drop for an island of a given cutout width.
	package static func dropHeight(cutoutWidth: CGFloat) -> CGFloat {
		gap + cutoutWidth + shadowRoom
	}
}

/// The panel's timings, in one place.
///
/// They have to be shared, because the controller tears the window down on a timer and the
/// view animates on a curve — and when those two numbers lived apart they disagreed. The
/// teardown fired at 0.5s against a spring whose *response* alone was 0.58, so the last third
/// of every retract was cut off and the panel appeared to snap out of the notch.
package enum NotchAnimation {

	/// Growing out. A spring, because the panel emerges from a physical object and should
	/// carry a little momentum doing it — and because a spring survives interruption, which
	/// matters when a face arrives while the panel is still on its way out.
	package static let expand = Animation.spring(response: 0.3, dampingFraction: 0.9)
	package static let reducedDuration: TimeInterval = 0.14
	package static let reduced = Animation.easeOut(duration: reducedDuration)
	package static let feedback = Animation.easeOut(duration: 0.18)
	package static let islandExpand = Animation.spring(response: 0.36, dampingFraction: 0.94)

	/// Going home. Ease-out, and quicker than the grow.
	///
	/// Two changes from `.smooth(duration: 0.55)`.
	///
	/// The curve: `.smooth` is SwiftUI's stock ease, and stock easings are too weak to read
	/// as deliberate — this is the strong ease-out (0.23, 1, 0.32, 1), which leaves
	/// immediately and settles slowly.
	///
	/// The duration: 550ms was longer than the grow, which is backwards. An entrance is the
	/// part somebody is waiting for; an exit is the part they have already stopped caring
	/// about, and holding a panel on screen for over half a second after its job is done is
	/// how a status indicator starts feeling like an obstacle.
	package static let retractDuration: TimeInterval = 0.22
	package static var retract: Animation {
		.timingCurve(0.23, 1, 0.32, 1, duration: retractDuration)
	}

	/// Between phases — the drop opening and closing as the state changes.
	///
	/// Ease-in-**out**, not ease-out: this is not something entering or leaving, it is the
	/// same object changing shape on screen, and movement between two on-screen states wants
	/// symmetry at both ends.
	package static let phaseDuration: TimeInterval = 0.24
	package static var phase: Animation {
		.timingCurve(0.4, 0, 0.2, 1, duration: phaseDuration)
	}

	/// How long the controller must leave the window alive after asking it to retract.
	/// The margin is for the frame the animation finishes on.
	package static var teardownDelay: TimeInterval { max(retractDuration, phaseDuration) + 0.16 }
}

/// The one statement of how the semi-glass tint responds to its slider.
///
/// The lock screen panel and the settings preview both draw this; when the formula lived in
/// each separately they disagreed, and a preview that disagrees with the thing it previews
/// is worse than none.
package enum NotchGlass {
	/// 0 = clear, 1 = opaque. Runs nearly the whole visible range so the slider does
	/// something at every position; clamped so a light-wallpaper boost can't flatten its
	/// top end into a single value.
	package static func semiTint(transparency: Double, boost: Double) -> Double {
		min(0.96, 0.92 - 0.80 * transparency + boost)
	}

	/// Clearer than it was: a lower base tint so the wallpaper moves through it,
	/// with a specular edge over the glass so it still reads as a panel.
	package static func liquidTint(boost: Double) -> Double {
		min(0.55, 0.20 + boost)
	}
}
