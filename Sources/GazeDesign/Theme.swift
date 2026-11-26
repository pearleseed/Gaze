import AppKit
import SwiftUI

/// Design tokens.
///
/// The palette follows the system appearance. It used to be dark unconditionally, on the
/// reasoning that Gaze is dark on every Apple platform — but that is true of Apple's
/// *sheet*, which appears over whatever you were doing, not of a settings window that sits
/// among your other windows. A window that stays black while everything around it turns
/// white is the one that looks broken.
package enum Theme {

	/// A colour that resolves against whichever appearance it is drawn in.
	///
	/// AppKit does the resolving, not a `@Environment(\.colorScheme)` read, because these are
	/// static tokens with no view to read an environment from — and because it then works
	/// inside `NSHostingView`, popovers and menus, which do not always inherit the
	/// environment the way the view tree suggests.
	package static func dynamic(light: Color, dark: Color) -> Color {
		Color(
			nsColor: NSColor(name: nil) { appearance in
				appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
					? NSColor(dark) : NSColor(light)
			})
	}

	/// Glass tint, in whichever direction the appearance calls for.
	///
	/// This is the pair that has to flip. Every scrim in the window is black over a dark
	/// appearance, and the *same* black in light mode turns the glass into a grey smear —
	/// light glass is tinted with white.
	package static func scrim(_ opacity: Double) -> Color {
		dynamic(light: .white.opacity(opacity), dark: .black.opacity(opacity))
	}

	// MARK: - Colour

	/// Opaque ground, for the windows that are not vibrant — enrolment and the recognition
	/// test, both of which are full of camera preview and want no wallpaper behind them.
	///
	/// Pro Black: near-black base in both appearances (dark-first). White text on this
	/// ground holds WCAG AA by a wide margin.
	package static let background = dynamic(
		light: Color(red: 0.078, green: 0.078, blue: 0.082),
		dark: Color(red: 0.078, green: 0.078, blue: 0.082))

	/// A group's fill — and, since `GlassSurface` lost its outline, the only thing marking
	/// where a group starts and stops.
	///
	/// Light mode takes white rather than a lightened black — Jis G Jacob's point, and the
	/// right one: a group in light mode is a white card, not a pale grey one.
	///
	/// It was 0.07 in dark, which is barely a tint: it could afford to be that faint only
	/// because a hairline was drawn round it to say where the edge was. Tone has to carry
	/// that on its own now, the way System Settings does it, so the step up from the ground
	/// is a step you can actually see.
	/// Dark: graphite over black. Light: a faint grey wash over the pale ground, the way
	/// System Settings groups read in a light appearance.
	package static let surface = dynamic(light: .black.opacity(0.05), dark: .white.opacity(0.12))
	package static let surfaceRaised = dynamic(light: .black.opacity(0.08), dark: .white.opacity(0.18))
	/// Settings groups only: a calmer, more solid neutral fill so rows stay readable over
	/// wallpaper. Graphite in dark, near-white in light.
	package static let settingsGroupFill = dynamic(light: Color(white: 1).opacity(0.86), dark: Color(white: 0.14).opacity(0.86))
	/// Keep the original group tint over the Semi Liquid Glass backdrop.
	package static let settingsGlassGroupFill = surface
	package static let separator = dynamic(light: .black.opacity(0.1), dark: .white.opacity(0.09))

	package static let setupGround = dynamic(light: Color(white: 0.96), dark: .black)
	/// The muted line under a title — same level as `secondaryLabel` resolves to in dark.
	package static let setupSecondary = Color.primary.opacity(0.68)
	/// The quietest text — a "Not now", a caption. Matches `tertiaryLabel` in dark.
	package static let setupTertiary = Color.primary.opacity(0.52)
	/// An unfilled enrolment tick, and the placeholder ring before capture starts. Was three
	/// different values (`0.34,0.34,0.36`, `.white.opacity(0.14)`) for the one visual role.
	package static let tickEmpty = Color(white: 0.34)

	/// The ground every setup screen sits on.
	///
	/// Black, with one barely-there lift behind the content.
	///
	/// Flat black across a 560×720 panel has nothing in it to say where the front of the
	/// window is, so there is a single soft highlight centred where the figure sits — the
	/// thing the screen is about is also the brightest part of it. No vignette: there is
	/// nothing to darken towards from black, and the earlier one was only there to hold
	/// the window's edge against the desktop, which black does by itself.
	///
	/// 5%, which is under the threshold of reading as a gradient. It should not be visible
	/// as an effect; it should only be visible that the flat version was flat.
	@MainActor
	package static var setupBackground: some View {
		ZStack {
			setupGround

			RadialGradient(
				colors: [.white.opacity(0.05), .clear],
				center: UnitPoint(x: 0.5, y: 0.32),
				startRadius: 0,
				endRadius: 420
			)
		}
		.ignoresSafeArea()
	}

	// MARK: - Motion

	/// The app's timing, in one place.
	///
	/// These were scattered as literals — `.easeInOut(duration: 0.3)` for a step change,
	/// `.spring(response: 0.5, dampingFraction: 0.72)` for a mark, `.easeOut(0.22)` for a
	/// dim — which is why setup read as a stack of separate screens rather than one flow:
	/// nothing moved on a shared clock.
	///
	/// `standard` is Apple's own curve (0.32, 0.72, 0, 1) — the one UIKit and AppKit use
	/// for view transitions. It leaves immediately and arrives slowly, which is what makes
	/// a transition feel like the screen was already moving before you looked at it.
	package enum Motion {
		/// Screen-to-screen, and anything that moves a whole block of content.
		package static let standard = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.28)
		/// The same curve, shortened — a control changing state under the pointer.
		package static let quick = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.14)
		/// Something arriving that should feel physical: a tick, a mark, a result.
		package static let arrive = Animation.spring(response: 0.34, dampingFraction: 0.86)

		/// How far a block travels as it arrives. Small on purpose — a long slide reads
		/// as a page turn, and these are not pages.
		package static let rise: CGFloat = 8
		/// The blur an element carries in from. Enough to read as focus resolving; not
		/// enough to look like a mistake in a screenshot.
		package static let entryBlur: CGFloat = 3
	}

	// MARK: - Icon palette

	/// There isn't one. That is the palette.
	///
	/// This used to be six saturated hues — blue, orange, purple, pink, teal, indigo — one
	/// per settings row, on the argument that Apple colour-codes its own icons. Apple does,
	/// in the *top-level* list of System Settings, where the categories are fixed and
	/// learnable. Inside a pane it buys nothing: nobody navigates to a switch by remembering
	/// that it was the pink one, and five hues in a group of five rows is chroma with no
	/// information in it.
	///
	/// Monochrome tiles keep what the icon column is actually for — a shape per row to scan
	/// by — and hand the whole colour budget to state. When something in this window is
	/// coloured, it is because it is telling you something.
	package static let grey = Color(red: 0.56, green: 0.56, blue: 0.58)

	/// What a switched-on control's icon turns.
	///
	/// The argument against colour was that hue inside a pane carries no information. A
	/// switch is the exception: on and off is exactly the information an icon can carry, and
	/// carrying it in colour means the state of five switches reads in one glance instead of
	/// five. Grey when off, and this when on.
	package static let active = dynamic(
		light: Color(red: 0.00, green: 0.42, blue: 0.90),
		dark: Color(red: 0.16, green: 0.56, blue: 1.00))

	/// Label opacities are set against the *worst* case, not the average one.
	///
	/// White text on the dark ground, near-black on the light one; both ramps hold WCAG AA.
	/// Light used to be the dark values too, so choosing the Light theme changed nothing.
	package static let label = dynamic(light: Color(white: 0.11), dark: .white)
	package static let secondaryLabel = dynamic(light: .black.opacity(0.62), dark: .white.opacity(0.68))
	package static let tertiaryLabel = dynamic(light: .black.opacity(0.48), dark: .white.opacity(0.52))

	/// Controls are neutral.
	///
	/// Tinting every switch, slider and icon green made the whole window read as one
	/// undifferentiated colour, so the green stopped meaning anything. Reserving it for
	/// Gaze itself — the glyph, the enrolment ring, the success tick — is what gives it
	/// back its meaning: green here says *recognised*, not *this is a control*.
	/// Black and white, which is exactly what an accent of "no colour" means in each
	/// appearance — and what makes a filled button read as filled in both.
	package static let accent = dynamic(light: .black, dark: .white)

	/// What a filled control's label is knocked out in: the opposite of `accent`.
	package static let onAccent = dynamic(light: .white.opacity(0.95), dark: .black.opacity(0.88))

	/// Selected and hovered rows: a white wash on dark, a grey wash on light.
	package static let selection = dynamic(light: .black.opacity(0.08), dark: .white.opacity(0.16))
	package static let hoverFill = dynamic(light: .black.opacity(0.05), dark: .white.opacity(0.07))

	/// Sampled neon green. Gaze identity only, never chrome.
	package static let faceID = Color(red: 74.0 / 255.0, green: 238.0 / 255.0, blue: 127.0 / 255.0)
	/// Dim green for the fail end-state: the same hue held back, not grey.
	package static let faceIDDim = Color(red: 34.0 / 255.0, green: 100.0 / 255.0, blue: 55.0 / 255.0)
	package static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)
	package static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)

	// MARK: - Metrics

	/// Generous and continuous. Small radii on a dark panel read as a dialog box; the
	/// system's own glass surfaces — Spotlight, the Siri panel, the notch capsule this app
	/// already draws — are much rounder than a settings group used to be.
	package static let cornerRadius: CGFloat = 16
	package static let rowInset: CGFloat = 18
	package static let sectionSpacing: CGFloat = 16
}
