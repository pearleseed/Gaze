import GazeCore
import GazeDesign
import SwiftUI

extension NotchCapsule {

	/// Proportional to what is actually showing, not to the window.
	///
	/// This was a constant 15 derived from the window height, so a panel retracting through
	/// its last twenty points kept a 15pt radius on a shape only a few points tall — which
	/// is what made the retract go square and hard right before it vanished. Tying the
	/// radius to the visible drop lets it round off to nothing as the panel closes.
	/// Floored, not just derived.
	///
	/// A radius proportional to the drop goes to nothing as the panel retracts, and the last
	/// thing you see before it disappears is a hard-cornered rectangle. The floor keeps the
	/// resting lip rounded, which is the whole reason it hangs below the cutout at all.
	/// Capped at 26, not 15.
	///
	/// 15 was set when the panel was small, and on a fully dropped panel it reads as a
	/// square-cornered box — the corner is there but too tight to see against 160pt of
	/// height. The floor and the divisor are unchanged, so the retracting animation still
	/// keeps its rounded lip all the way down; only the ceiling moved.
	private var cornerRadius: CGFloat {
		usesCompactBar ? 9 : min(36, max(9, max(0, visibleHeight) / 1.9))
	}

	// MARK: - Island

	/// Whether this panel is the detached island rather than the attached drop.
	///
	/// Compact phases stay attached whatever the setting: the resting padlock lives in the
	/// menu bar band, and an island cannot be at rest — it is the thing that pops out.
	internal var isIsland: Bool { model.shape == .island && showsDrop }

	internal static var islandGap: CGFloat { IslandMetrics.gap }

	/// A rounded card hanging below the housing, the way Apple Pay's drops from the
	/// Dynamic Island — a continuous squircle, never a wide slab.
	private var islandShape: RoundedRectangle {
		RoundedRectangle(cornerRadius: min(28, islandHeight * 0.32), style: .continuous)
	}

	/// One dimension, used for both.
	/// As wide as the housing it comes out of.
	///
	/// It was a fraction of the window, and the window is deliberately wider than the cutout
	/// — so the island came out narrower than the notch and read as unrelated to it. Matching
	/// the cutout is what makes it look like the thing the notch handed down.
	private var islandSide: CGFloat {
		let available = height - notchInset - Self.islandGap - Self.islandShadowRoom
		return max(0, min(cutoutWidth > 0 ? cutoutWidth : width * 0.52, available))
	}

	private static var islandShadowRoom: CGFloat { IslandMetrics.shadowRoom }

	internal var islandHeight: CGFloat { islandSide }
	internal var islandWidth: CGFloat { islandSide }

	/// How far the island travels on its way out of the housing.
	///
	internal var islandHiddenOffset: CGFloat { -12 }

	/// Nebulark's gradient: black at the top running into green at the bottom.
	///
	/// Green only ever appears while the island is doing something — it has no resting
	/// state — so this keeps the rule the rest of the app follows, that green means Gaze
	/// and nothing else, while taking the look he built.
	/// Two gradients, not one, because they were two jobs sharing a stop list.
	///
	/// Turning the green down also turned the *black* down — the stops ran from black at the
	/// top to green at the bottom, so the bottom of the panel had nothing dark left in it and
	/// the glass simply showed the wallpaper through. Over a bright desktop the island came
	/// out pale blue.
	///
	/// The dark keeps the panel legible from top to bottom. The green is a separate wash on
	/// top of it, so it can be dialled to a hint without taking the ground with it.
	private var islandTint: LinearGradient {
		LinearGradient(
			stops: [
				.init(color: .black.opacity(0.94 + lightWallpaperBoost), location: 0),
				.init(color: .black.opacity(0.90 + lightWallpaperBoost), location: 0.45),
				.init(color: .black.opacity(0.84 + lightWallpaperBoost), location: 1),
			],
			startPoint: .top,
			endPoint: .bottom)
	}

	/// A hint, at the bottom, and nowhere else.
	private var islandGreen: LinearGradient {
		LinearGradient(
			stops: [
				.init(color: .clear, location: 0.42),
				.init(color: Theme.faceID.opacity(0.05), location: 0.72),
				.init(color: Theme.faceID.opacity(0.15), location: 1),
			],
			startPoint: .top,
			endPoint: .bottom)
	}

	internal var flareRadius: CGFloat {
		min(17, max(0, usesCompactBar ? restingBarHeight - notchInset : visibleHeight) / 2.4)
	}

	private var shape: NotchPanelShape {
		NotchPanelShape(topRadius: flareRadius, bottomRadius: cornerRadius)
	}

	/// The visible screen either side of the cutout, in whichever shape is currently drawn.
	private var earWidth: CGFloat { max(0, (compactBarWidth - cutoutWidth) / 2) }

	private var showsChallengeCaption: Bool {
		model.showsCaptions && model.phase.captionText != nil
	}

	private var hidesReturnCaption: Bool {
		model.phase.isReturningToRest && !reduceMotion
	}

	internal var challengeCaption: some View {
		ZStack {
			if showsChallengeCaption, let prompt = model.phase.captionText {
				HStack(spacing: 5) {
					if let symbol = model.phase.captionSymbol {
						Image(systemName: symbol)
							.font(.system(size: 10, weight: .semibold))
							// The words beside it already animate on change; without this the
							// glyph was the one thing that cut. Directional rather than magic:
							// a movement prompt and a rejection share no shape to morph.
							.contentTransition(.symbolEffect(.replace.downUp))
							.accessibilityHidden(true)
					}
					Text(prompt)
						.font(.system(size: 11, weight: .medium))
						.multilineTextAlignment(.center)
						.lineLimit(2)
						.fixedSize(horizontal: false, vertical: true)
				}
				.foregroundStyle(.white)
				.opacity(hidesReturnCaption || !model.showsCaptions ? 0 : 1)
				// Always hidden: GazeFaceMark already announces this same text, so
				// exposing the caption would read every state twice.
				.accessibilityHidden(true)
				.id(prompt)
				.transition(
					.asymmetric(
						insertion: .move(edge: .bottom).combined(with: .opacity),
						removal: .move(edge: .top).combined(with: .opacity)))
			}
		}
	}

	/// The detached island.
	///
	/// Honours Style, which it did not before: the fill was hardcoded, so choosing Normal or
	/// Liquid Glass changed the bar above the island and left the island itself identical.
	/// A style setting that visibly applies to one half of the panel is worse than none.
	///
	/// Nebulark's green stays in every style — it is the island's own identity rather than a
	/// property of the material, and it is the one thing that makes this shape *this* shape.
	@ViewBuilder
	internal var islandBody: some View {
		if model.style == .liquidGlass {
			// Glass has no fill to hang a backing off: the ultra-thin backing and the green
			// wash over it were what made this a flat grey slab with murky green at the
			// bottom. The green stays as light along the lower rim instead.
			liquidSurface(islandShape, outline: .rounded(islandShape.cornerSize.width))
				.shadow(color: .black.opacity(0.3), radius: 18, y: 8)
				.overlay { islandGlow }
		} else {
			islandShape
				.fill(islandFill)
				.background { islandBacking.shadow(color: .black.opacity(0.35), radius: 18, y: 8) }
				.overlay { islandShape.fill(islandGreen).blendMode(.sourceAtop) }
				.overlay { islandEdge }
		}
	}

	/// Nebulark's green on glass: a soft glow at the bottom edge, not a fill.
	private var islandGlow: some View {
		islandShape
			.strokeBorder(Theme.faceID.opacity(0.45), lineWidth: 2)
			.blur(radius: 4)
			.mask {
				LinearGradient(
					stops: [.init(color: .clear, location: 0.55), .init(color: .black, location: 1)],
					startPoint: .top, endPoint: .bottom)
			}
			.clipShape(islandShape)
			.allowsHitTesting(false)
	}

	/// Liquid glass gets the specular edge; Solid and Frosted get a hairline.
	@ViewBuilder
	private var islandEdge: some View {
		if model.style == .liquidGlass {
			liquidEdge(over: islandShape)
		} else {
			islandShape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
		}
	}

	/// The island's own colour, at the density the chosen style asks for.
	private var islandFill: Color {
		switch model.style {
		case .normal:
			return .black
		case .semiLiquidGlass:
			return .black.opacity(
				NotchGlass.semiTint(transparency: model.transparency, boost: lightWallpaperBoost))
		case .liquidGlass:
			return .black.opacity(liquidTint)
		}
	}

	/// A blur behind the translucent styles, and nothing behind the solid one.
	@ViewBuilder
	private var islandBacking: some View {
		if model.style == .normal {
			islandShape.fill(.black)
		} else {
			islandShape.fill(.ultraThinMaterial)
		}
	}

	/// The panel body.
	///
	/// Three styles, chosen in Settings: solid black, or black at a chosen opacity over a
	/// blurred material. The material is applied here rather than relying on `.glassEffect`
	/// to sample the wallpaper — this window lives in its own SkyLight space, so there is
	/// nothing behind it in the compositor for a material to blur, and unbacked glass falls
	/// back to a pale grey slab on a dark lock screen.
	internal var background: some View {
		Group {
			switch model.style {
			case .normal:
				// Genuinely opaque, and genuinely *un-faded*.
				//
				// This used to be masked to clear at the bottom like the other two, which
				// meant the one style whose whole promise is "solid black, indistinguishable
				// from the cutout" was neither solid nor black below its first third. It
				// looked washed next to the glass styles it was supposed to contrast with.
				shape.fill(.black)

			case .semiLiquidGlass:
				// Dark, with the wallpaper's light coming through a blur. The slider moves
				// how much — across a range you can actually see.
				//
				// The tint ran 0.55…0.90, a 35% band at the dark end, so dragging the
				// slider from one stop to the other changed almost nothing and the control
				// read as broken. It runs nearly the whole way now.
				shape
					.fill(.black.opacity(glassTint))
					.background { shape.fill(.ultraThinMaterial) }
					.mask { fade }

			case .liquidGlass:
				// The real macOS 26 material — it refracts and picks up what is behind
				// it rather than just being a dark tint over a blur.
				liquidSurface(shape, outline: .panel(shape))
					.mask { fade }
			}
		}
	}

	/// Fades to clear toward the bottom, so a glass panel has no visible end and reads as
	/// the notch extending rather than a rectangle stuck under it.
	///
	/// Only while it is extending. The resting bar sits inside the menu bar band, where a
	/// fade has nothing to resolve into — it just softens the one edge that should be as
	/// crisp as the housing it continues, and every other notch app's bar is crisp there.
	private var fade: some View {
		// Applied only when this shape *is* the panel that hangs below the housing.
		//
		// In island and ear modes the background is the resting bar and nothing more — the
		// island is a separate object below it, and on the ear nothing drops at all. A
		// gradient meant for a tall panel was dissolving the bottom third of a shape exactly
		// one notch tall, so the bar came out visibly shorter than the housing beside it.
		// Stating the condition positively is what stops this needing fixing once per mode.
		let stops: [Gradient.Stop] =
			barIsTheDrop
			? [
				.init(color: .black, location: 0),
				.init(color: .black, location: 0.36),
				.init(color: .black.opacity(0.72), location: 0.55),
				.init(color: .black.opacity(0.38), location: 0.76),
				.init(color: .black.opacity(0.12), location: 0.92),
				.init(color: .clear, location: 1),
			]
			: [
				.init(color: .black, location: 0),
				.init(color: .black, location: 1),
			]
		return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
	}

	/// The padlock, in the screen beside the cutout.
	///
	/// A bare glyph, with nothing behind it.
	///
	/// It used to sit in a circle — `black 0.55` over `.ultraThinMaterial`, ringed in white.
	/// Every one of those layers was working against it: a translucent dark fill laid over a
	/// band that is *already* black comes out **lighter** than its surroundings, so the
	/// container read as a grey disc stuck onto the notch, and the ring drew a hard outline
	/// around the blob. It looked applied, not built in.
	///
	/// The band it stands on is the panel's own black, so there is nothing to separate the
	/// glyph from — it can simply be drawn into the bar. That is the whole difference
	/// between a status indicator and a sticker.
	internal var lockChip: some View {
		Image(systemName: model.phase == .unlocked ? "lock.open.fill" : "lock.fill")
			.accessibilityLabel(model.phase.markAccessibilityLabel)
			.font(.system(size: 11, weight: .semibold))
			// White, not green. This is the menu bar's own vocabulary — the padlock beside
			// the cutout is a status glyph like the ones to its right, and those are never
			// coloured. Green was borrowed from a confirmation panel that no longer exists.
			.foregroundStyle(.white)
			// The shackle morphs rather than the glyph swapping, so it reads as one padlock
			// opening rather than two icons exchanged.
			.contentTransition(.symbolEffect(.replace.magic(fallback: .replace.downUp)))
			// The one mechanical beat in an otherwise smooth sequence: a lock lets go all at
			// once.
			.symbolEffect(.bounce.up, options: .speed(0.9), value: model.phase == .unlocked)
			// No chip behind it.
			//
			// It briefly had one, added when the resting panel was hidden behind the housing
			// and the padlock was left standing on bare wallpaper with nothing to read
			// against. Now that the panel is back to full width, the glyph stands on the
			// panel's own black again — and a translucent dark chip laid over black comes out
			// *lighter* than what surrounds it, which is what made it look like a sticker
			// pasted next to the notch rather than part of it.
			//
			// Optically centred in the bar it stands on, lip included — centring it on the
			// housing alone pushed it up against the top edge once the bar grew.
			.frame(width: earWidth, height: restingBarHeight)
	}

	/// Flush with the cutout while resting, the full drop once it is scanning.
	///
	/// The 11pt lip this had was almost the entire overhang: the notch is 32pt tall and a
	/// notch app's bar sits flush with it, so anything hanging below shows as a second shape
	/// behind the first. Nothing hangs below now — the resting bar occupies the menu bar band
	/// and no more, and its corners round *within* that band, which is what the radius floor
	/// is for.
	internal var currentHeight: CGFloat {
		isCompactPhase ? restingBarHeight : height
	}

	/// The bar that carries the padlock: the housing's height plus a single point.
	///
	/// It looked short once, but that was the bottom fade dissolving its lower third rather
	/// than the height being wrong — and a 12pt lip added to "fix" it made the bar hang below
	/// the notch, which is worse than either.
	///
	/// The one point is not a fudge. Flush leaves the bar's bottom edge and the housing's on
	/// exactly the same line, and any rounding in either direction shows as a hairline of
	/// wallpaper between them; a point of overlap guarantees they meet.
	internal var restingBarHeight: CGFloat { notchInset + 1 }

	/// Narrower while resting, full width once it drops.
	///
	/// Deliberately smaller than the bar a notch app draws over the same area. Theirs
	/// is about 276pt across and flush with the menu bar; ours resting inside that
	/// disappears under it entirely, instead of peeking out a few points wider and lower and
	/// reading as a second notch behind the first.
	///
	/// It still has to look right on its own, so this is a smaller version of the same shape
	/// rather than nothing at all — rounded, ears either side of the housing, just tighter.
	internal var backgroundWidth: CGFloat {
		// Going home: narrow to the cutout, so the whole shape ends up behind the housing.
		//
		// The retract used to bring the height down to the menu bar band and stop there,
		// leaving the bar's ears — 36pt either side of the camera housing — sitting on open
		// menu bar. Those are visible screen, so ordering the window out made them disappear
		// in one frame: the height animated beautifully and then the last of it went *boop*.
		//
		// Collapsing the width as well means the bar slides in behind the cutout and there is
		// nothing left on screen to pop when the window goes.
		guard expanded else { return cutoutWidth }
		return isCompactPhase ? compactBarWidth : width
	}

	/// The bar at rest: the housing plus a short ear either side.
	internal var compactBarWidth: CGFloat {
		min(width, cutoutWidth + 2 * Self.restingEar)
	}

	/// Screen either side of the housing that the resting bar covers.
	private static let restingEar: CGFloat = 36

	/// The part of the panel that actually shows below the cutout.
	private var visibleHeight: CGFloat { currentHeight - notchInset }

	/// Whether the island is currently down out of the notch.
	internal var islandIsOut: Bool { isIsland && expanded }

	/// True when the background shape is the panel that hangs below the housing, rather than
	/// just the bar the padlock sits on.
	private var barIsTheDrop: Bool { showsDrop && !isIsland }

	/// Whether anything drops out of the notch at all.
	///
	/// The ear flank and the dynamic island carry their captions inline, so neither
	/// uses the drop.
	internal var showsDrop: Bool { !isCompactPhase }

	/// Vertical room the challenge caption needs in the drop — held whether or not a
	/// caption is currently showing.
	///
	/// Reserving it on the caption's *presence* is what made the mark change size and
	/// position the instant a prompt cleared, which is the same instant the unlock animation
	/// begins: the tick appeared larger and lower than the face that had just been there, so
	/// the whole mark seemed to jump. The band is now always held, so the mark is one size in
	/// every phase of the drop and only the caption fades in and out beneath it.
	private static let captionBand: CGFloat = 30
	internal var glyphSide: CGFloat {
		model.shape == .island
			? min(islandWidth, islandHeight) * 0.62
			: min(width, max(0, visibleHeight - Self.captionBand)) * 0.80
	}

	/// Sits high in the drop, where the panel is still dark enough to carry it.
	internal var glyphTop: CGFloat {
		guard !isIsland else {
			// Centred, because an island has no fade to stay clear of and no housing to sit
			// under — it is a panel in its own right.
			return notchInset + Self.islandGap + (islandHeight - glyphSide) / 2
		}
		return notchInset + max(6, (visibleHeight - glyphSide - Self.captionBand) / 2)
	}

	internal var content: some View {
		NotchFaceMark(phase: model.phase, usesNativeAnimation: model.usesNativeAnimation,
			colour: model.animationColour, active: model.isExpanded && !isCompactPhase)
			.frame(width: glyphSide, height: glyphSide)
	}
}
