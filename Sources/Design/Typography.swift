import SwiftUI

/// The type scale.
///
/// Every size in the app comes from here. It used to be a dozen loose `.system(size:)`
/// literals scattered across the views — 9, 10, 11, 12, 13, 14, 15, 19, 20 — which is a
/// spread rather than a scale, and it showed: rows and their details differed by a point in
/// one window and three in another.
///
/// These are macOS's own text styles rather than fixed sizes, so they match the metrics
/// AppKit uses for the same job (`.body` *is* 13pt, `.callout` 12, `.subheadline` 11) and
/// they follow the system text size where the user has changed it. Nothing is below
/// `.caption` — 10pt is the floor macOS draws at, and the 9pt labels that were here before
/// were under it.
enum Typography {

	/// The pane heading in the detail column.
	static let paneTitle = Font.system(.title2, weight: .bold)

	// The three setup sizes below are larger than any macOS text style, so they are written
	// as a style *scaled* rather than as a fixed point size.
	//
	// `Font.system(size:)` does not move when somebody raises their text size — it is a
	// number of points, forever — and these three carry every word on the setup screens:
	// the title, the one line under it, and the hero. Set as literals, the flow that
	// introduces the app was the part of the app that ignored the accessibility setting
	// most completely.
	//
	// Anchored to the closest style rather than all to `.body`, because the styles do not
	// grow at the same rate at accessibility sizes — a display face is meant to grow more
	// slowly than body copy, and scaling a title from `.body` would have it overtake
	// everything around it. macOS's own metrics are `.body` 13pt and `.largeTitle` 26pt,
	// which is where the ratios come from.

	/// A setup screen's title. One size across welcome / capture / done, where there used to
	/// be three (25 / 26 / 30pt) for the same "screen title" role.
	static let setupTitle = Font.largeTitle.weight(.bold).scaled(by: 34.0 / 26.0)

	/// The one line on the opening screen, and nothing else.
	///
	/// Bigger than `setupTitle` and tracked tighter. A hero line set at body tracking
	/// looks like a heading that happened to be large; the negative tracking is most of
	/// what separates a product's first screen from a dialog's.
	static let setupHero = Font.largeTitle.weight(.bold).scaled(by: 52.0 / 26.0)

	/// Body copy under a setup title.
	static let setupBody = Font.body.scaled(by: 14.0 / 13.0)

	/// A group's heading.
	static let groupTitle = Font.headline

	/// A row's label, and body copy generally.
	static let row = Font.body

	/// The explanatory line under a row's label, and a group's footer.
	static let detail = Font.subheadline

	/// Text inside a control — buttons, pop-up menus, value read-outs.
	static let control = Font.callout

	/// The status line in the hero row.
	static let heroTitle = Font.system(.title3, weight: .semibold)

	/// A large figure that changes — a score, a peak. Rounded because it is a *number*
	/// being read as a quantity, which is the one place macOS uses the rounded face.
	static let metric = Font.system(.title2, design: .rounded, weight: .semibold)

	/// The caption over a metric.
	static let metricLabel = Font.system(.caption, weight: .semibold)

	/// Figures that must line up column-wise between frames — a score that updates ten
	/// times a second jitters horribly in a proportional face.
	static let mono = Font.system(.subheadline, design: .monospaced, weight: .medium)

	/// The value pill on a slider.
	static let pill = Font.system(.caption, design: .rounded, weight: .medium)

	/// The smallest thing in the app.
	static let caption = Font.caption

	/// The Gaze mark used as a picture rather than as text — the hero row, the About
	/// panel. Fixed rather than scaled: this is an illustration sized against the layout
	/// around it, and it is never the only statement of what it says.
	///
	/// This is the rule the rest of the app's remaining `.system(size:)` literals follow.
	/// Text scales; drawings do not. `StoredPasswordRowArt` and `PermissionRowIllustration`
	/// are reconstructions of real rows, composed at the size they are displayed, and the
	/// notch panel is drawn against a physical cutout — grow the type inside any of them and
	/// the picture stops being a picture of the thing. A fixed size in one of those is a
	/// decision, not an oversight.
	static let glyph = Font.system(size: 34, weight: .thin)
	static let glyphLarge = Font.system(size: 40, weight: .thin)
}
