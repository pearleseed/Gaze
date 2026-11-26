import AppKit
import GazeCore
import GazeDesign
import SwiftUI

/// The panel that drops out of the notch while Gaze runs.
///
/// Shaped to read as the notch itself growing downwards: same width as the camera
/// housing, square across the top where it meets the cutout, rounded only along the
/// bottom — the way the Dynamic Island expands.
package struct NotchCapsule: View {

	@Bindable package var model: NotchCapsuleModel
	package var width: CGFloat
	package var height: CGFloat
	/// Top strip hidden behind the physical cutout. Content is centred below it.
	package var notchInset: CGFloat = 0
	/// The physical cutout's width. The window is wider than it, and the difference is the
	/// screen either side of the camera housing — where a padlock can sit at menu bar height
	/// without dropping anything out of the notch at all.
	package var cutoutWidth: CGFloat = 0
	/// False on screens without a physical notch, where Connected + Beside the camera
	/// falls back to the centred panel.
	package var hasNotch: Bool = true

	package init(
		model: NotchCapsuleModel,
		width: CGFloat,
		height: CGFloat,
		notchInset: CGFloat = 0,
		cutoutWidth: CGFloat = 0,
		hasNotch: Bool = true
	) {
		self.model = model
		self.width = width
		self.height = height
		self.notchInset = notchInset
		self.cutoutWidth = cutoutWidth
		self.hasNotch = hasNotch
	}

	@Environment(\.accessibilityReduceMotion) private var systemReduceMotion
	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
	@Environment(\.colorSchemeContrast) private var contrast
	@Environment(\.notchReduceMotion) private var previewReduceMotion
	/// Shared morph space for the panel's glass pieces, so splits and rejoins reshape
	/// rather than swap. Visuals, shapes and timings are unchanged; this only coordinates.
	@Namespace internal var panelGlass
	internal var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
	// Reduce Motion skips the grow-out by reading as expanded, so opacity must never gate on isExpanded — that would blank the resting padlock.
	internal var expanded: Bool { reduceMotion || model.isExpanded }

	/// Whether the phase is drawn as the resting bar rather than the dropped panel.
	///
	/// Normally this is just `phase.isCompact`, and every geometry decision below reads
	/// it here rather than the phase, so there is one answer to "which shape is drawn".
	///
	/// The one exception is the unlock. `.unlocked` collapses immediately in the drawn-head
	/// design because the padlock opening is the only thing left to say, and it says it
	/// from the bar — but the watcher keeps the panel alive for three seconds after the
	/// unlock (`LockWatcher.unlockAnimationDuration`), and the native animation has
	/// something worth showing for those three seconds: the tick. With it on, the panel
	/// stays dropped and plays that clip before retracting.
	///
	/// Guarded on the clips actually being in the bundle: a build without them falls
	/// straight through to the old behaviour rather than holding a panel open on an
	/// animation it cannot play.
	internal var isCompactPhase: Bool {
		guard model.phase == .unlocked, model.usesNativeAnimation,
			NativeUnlockAssets.isAvailable(colour: model.animationColour)
		else { return model.phase.isCompact }
		return false
	}

	/// How far the top corners flare out into the screen edge.
	///
	/// Grows with the panel rather than being fixed. Collapsed, the panel is hidden behind
	/// the physical cutout and a flare there would put two curves on screen that belong to
	/// nothing; as it drops, the flare opens with it so the join is always the width of the
	/// thing it is joining.
	internal var usesCompactBar: Bool { isIsland || isCompactPhase }

	package var body: some View {
		// The glass crop is measured from the panel view, not the screen, so the Settings
		// preview lines up as well as the lock screen does.
		capsuleBody.coordinateSpace(.named(GlassBackdrop.space))
	}

	private var capsuleBody: some View {
		// One morph space for every glass piece below: the container coordinates
		// the glassEffectID identities while layout and timings stay as they are.
		GlassEffectContainer(spacing: 12) {
			ZStack(alignment: .top) {
			// Grows downward out of the cutout and retracts back into it. Collapsed, the
			// shape is exactly the notch's height, so it is completely hidden behind the
			// physical cutout — nothing appears or disappears, it emerges.
			// The bar is always drawn in the attached and island modes. The ear flank
			// draws its own flanking silhouette instead (see earBody), and the
			// dynamic island draws its own floating capsule (see dynamicBody).
			//
			// Island mode used to draw the island *instead* of it, which left the padlock
			// standing on bare menu bar with nothing behind it — the chip's ground is the
			// bar, and taking the bar away took the ground with it. The bar is the notch;
			// the island is a thing the notch hands down. Both, always.
			if isEarFlank {
				earBody
			} else if isDynamicIsland {
				dynamicBody
			} else {
				background
					.glassEffectID("panel", in: panelGlass)
					.glassEffectUnion(id: "panel", namespace: panelGlass)
					.glassEffectTransition(.identity)
				// Widened by the flare on each side, not narrowed by it.
				//
				// `NotchPanelShape` insets its body to leave room for the flares, so
				// passing `backgroundWidth` straight through made the panel's body 2×12pt
				// narrower than it had been — the walls moved inward and the panel stopped
				// lining up with the cutout. Adding the flare back on means the body stays
				// exactly `backgroundWidth` and the wings extend beyond it, which is what
				// "flared" is supposed to mean.
				.frame(
					width: (expanded && usesCompactBar ? compactBarWidth : backgroundWidth) + flareRadius * 2,
					height: expanded
						? (isIsland ? restingBarHeight : currentHeight)
						: notchInset)
			}

			// Always in the hierarchy while this is island mode, shown or not.
			//
			// It used to be inserted the moment scanning began, so its offset and scale were
			// already at their final values when it appeared — it popped into place with no
			// travel at all, while the attached panel got the full spring. Keeping the view
			// mounted and animating a *value* is what gives both shapes the same timing.
			if model.shape == .island {
				islandBody.glassEffectID("island", in: panelGlass)
					.glassEffectTransition(.materialize)
					.frame(width: islandWidth, height: islandHeight)
					// The mark rides *inside* the island rather than being positioned against
					// the window. Drawn separately it stayed at its final place while the
					// island travelled, so the two came apart mid-animation and the glyph
					// hung below a panel that had not arrived yet.
					.overlay { content.frame(width: glyphSide, height: glyphSide) }
					.overlay(alignment: .bottom) {
						challengeCaption
							.padding(.horizontal, 10)
							.padding(.bottom, 14)
					}
					.scaleEffect(islandIsOut || reduceMotion ? 1 : 0.96, anchor: .top)
					.offset(y: islandIsOut || reduceMotion ? 0 : islandHiddenOffset)
					.opacity(islandIsOut ? 1 : 0)
					.padding(.top, notchInset + Self.islandGap)
					.animation(
						reduceMotion ? nil
							: (islandIsOut ? NotchAnimation.islandExpand : NotchAnimation.retract),
						value: islandIsOut)
			}

			// Locked: a padlock beside the cutout, at menu bar height.
			//
			// It used to hang below the notch on a stub of panel, which is the one place it
			// could not go — the drop is the *active* state, so a resting padlock sitting in
			// it said the panel was doing something when it was doing nothing. Notch apps
			// put a resting indicator in the screen either side of the housing instead, and
			// that is space this window already covers.
		// The padlock stays closed for the wait: pending shows the waiting words in the
		// drop and the same padlock shut where it has sat all along. Only the confirmed
		// unlock opens it.
			if !isEarFlank && !isDynamicIsland {
				lockChip
					// Always positioned against the *resting* bar, never the panel.
					//
					// This used `backgroundWidth`, which is the resting bar while compact and
					// the full window once a panel drops — so the padlock slid outward the
					// moment scanning began, ending up further left than the ear it had been
					// sitting in. The bar it belongs to does not move, so neither should it.
					.frame(width: compactBarWidth, alignment: .leading)
					.opacity(expanded ? 1 : 0)
					.transition(.opacity)
			}

			if showsDrop && !isIsland && !isEarFlank && !isDynamicIsland {
				VStack(spacing: 7) {
					content
						.frame(width: glyphSide, height: glyphSide)
					challengeCaption
				}
					.animation(reduceMotion ? nil : NotchAnimation.feedback, value: model.phase.captionText)
					// Centred in the solid band — not the whole window (whose top third is
					// behind the cutout) and not the whole visible drop (whose lower part
					// fades to clear, which would dissolve the glyph along with it).
					.padding(.top, glyphTop)
					.opacity(expanded ? 1 : 0)
					.scaleEffect(expanded || reduceMotion ? 1 : 0.94, anchor: .top)
					// Out before the panel is, so the panel never closes over a glyph that
					// is still solid — that overlap is what made the retract look like two
					// separate events instead of one.
					.animation(reduceMotion ? nil : NotchAnimation.feedback, value: expanded)
			}
		}
		.frame(width: width, height: height, alignment: .top)
		// Separate transactions: expand/retract timing for the drop, quicker
		// feedback timing for phase and caption changes.
		.animation(
			reduceMotion ? nil : (expanded ? NotchAnimation.expand : NotchAnimation.retract),
			value: expanded)
		.animation(
			reduceMotion ? nil : NotchAnimation.feedback,
			value: [String(describing: isCompactPhase), model.phase.captionText ?? ""].joined(separator: "|"))
		.symbolEffectsRemoved(reduceMotion)
		}
	}

	internal static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
		(text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width.rounded(.up)
	}

	internal var glassTint: Double {
		NotchGlass.semiTint(transparency: model.transparency, boost: lightWallpaperBoost)
	}

	/// Liquid glass follows the Transparency slider too: clearer as it rises.
	/// Scaled rather than direct, so full transparency stays a panel, not a hole.
	internal var liquidTint: Double {
		min(0.6, max(0, NotchGlass.liquidTint(boost: lightWallpaperBoost) * (1.2 - model.transparency)))
	}

	/// The Liquid Glass surface in any of the panel's shapes.
	///
	/// Drawn from the wallpaper when the controller has one: this window sits in the lock
	/// screen's own space, where `.glassEffect` samples nothing and renders as an opaque slab.
	/// The settings preview has no backdrop and a real window behind it, so it keeps the
	/// system glass. Reduce Transparency or Increase Contrast gets the solid panel.
	@ViewBuilder
	internal func liquidSurface<S: Shape>(_ shape: S, outline: GlassOutline) -> some View {
		if reduceTransparency || contrast == .increased {
			shape.fill(.black)
				.overlay { shape.stroke(.white.opacity(0.18), lineWidth: 1).clipShape(shape) }
		} else if let backdrop = model.backdrop {
			WallpaperGlass(
				backdrop: backdrop, shape: shape, outline: outline, lightBehind: model.lightBehind)
		} else {
			Color.clear.glassEffect(
				.clear.tint(.black.opacity(liquidTint)),
				in: shape)
				.overlay { liquidEdge(over: shape) }
		}
	}

	/// Specular edge over liquid glass, so the clearer tint still reads as a panel.
	internal func liquidEdge<S: Shape>(over shape: S) -> some View {
		// The dark panel recipe from the macOS 27 Figma kit, kept to what reads on a tinted
		// panel: light bands inside the top and bottom edges and thin side rims. Centred
		// strokes clipped to the shape, so they sit inside like strokeBorder but work for
		// the custom panel shape too.
		GeometryReader { _ in
			ZStack {
				shape.stroke(
					LinearGradient(
						colors: [.white.opacity(0.45), .white.opacity(0.08), .white.opacity(0.18)],
						startPoint: .top, endPoint: .bottom),
					lineWidth: 1)
				ForEach([CGFloat(-1.25), 1.25], id: \.self) { offset in
					shape.stroke(.white.opacity(0.14), lineWidth: 0.5)
						.offset(x: offset)
						.mask {
							LinearGradient(colors: [.black, .clear],
								startPoint: offset > 0 ? .leading : .trailing, endPoint: .center)
						}
				}
			}
			.clipShape(shape)
		}
		.allowsHitTesting(false)
	}

	/// Extra black mixed in when the wallpaper behind the panel is bright.
	///
	/// `lightBehind` was computed on every show — `WallpaperBrightness.isLight(on:)`, set
	/// on the model, and then read by nothing at all. The whole point of measuring it is
	/// this: over a pale wallpaper both glass styles wash out and a white glyph on them has
	/// almost no contrast left. Only the two translucent styles use it; `.normal` is already
	/// solid black and has nothing to gain.
	internal var lightWallpaperBoost: Double { model.lightBehind ? 0.22 : 0 }
}
