import GazeDesign
import SwiftUI

extension NotchCapsule {

	// MARK: - Ear flank (Connected + Beside the camera)

	/// Connected with the mark beside the camera: black flanking the housing on both
	/// sides, never over it. The middle of the row is the physical cutout, so nothing
	/// is drawn there.
	///
	/// Only Connected offers the choice, and only on a screen with a physical notch to
	/// flank — without one this falls back to the centred panel, as before.
	internal var isEarFlank: Bool {
		model.shape == .attached && model.glyphPlacement == .ear && hasNotch
	}

	private enum EarFlankMetrics {
		/// Black beside the cutout on each side. The resting silhouette is the cutout
		/// plus twice this, and grows only sideways from there.
		static let flank: CGFloat = 54
		/// The cutout's own height cannot change, so this is the visible black below it.
		static let heightBump: CGFloat = 8
		static let topRadius: CGFloat = 12
		static let bottomRadius: CGFloat = 12
		static let lockSize: CGFloat = 15
		static let faceSize: CGFloat = 30
		/// Past this width the caption truncates with an ellipsis. The window controller
		/// sizes the ear window for this, so the two must change together.
		static let maxCaptionWidth: CGFloat = 170
	}

	/// The one-line caption on the face-side flank. Only the phases that carry
	/// guidance show it here: challenge prompts and the two rejection captions. Pending
	/// and success keep the resting silhouette.
	///
	/// Same titles the island carries: the prompt without its " · N of M" step suffix,
	/// which the flank has no room for — the island splits that half into a subtitle.
	///
	/// `.scanning` and `.success` are the two it did *not* carry, and that omission is what
	/// moved the mark. The flank measured its width from whatever sentence was in hand, so
	/// a plain rejection — the first words an unchallenged scan ever sees — had to grow the
	/// silhouette underneath the mark by ~146pt at the very moment the failure animation
	/// began. A scan with a movement prompt had no such jump, because the prompt had
	/// already widened the bar: exactly the asymmetry between the two paths.
	///
	/// Everything but the closed padlock now speaks, so the bar opens once when the attempt
	/// starts and no later caption can ask it to move again.
	private var earCaption: String? {
		guard model.showsCaptions else { return nil }
		switch model.phase {
		case .challenge(let prompt, _, _, _, _, _) where !prompt.isEmpty:
			let parts = prompt.components(separatedBy: " · ")
			return parts.count > 1 ? parts.dropLast().joined(separator: " · ") : prompt
		case .scanning:
			return "Looking for you"
		case .pending:
			return NotchCapsuleModel.Phase.pendingCaption
		case .notRecognised:
			return NotchCapsuleModel.Phase.notRecognisedCaption
		case .spoofRejected:
			return NotchCapsuleModel.Phase.spoofRejectedCaption
		case .unavailable(let message):
			return message
		case .success, .unlocked:
			return "Unlocked"
		default:
			return nil
		}
	}

	/// The measured words for the face-side flank, capped so a long prompt cannot push
	/// the silhouette past its window. A number, not a hug, so the
	/// flank width below animates as one value instead of re-measuring text each frame.
	private var earMessageWidth: CGFloat {
		guard let caption = earCaption else { return 0 }
		return min(Self.textWidth(caption, size: 12, weight: .semibold), EarFlankMetrics.maxCaptionWidth)
	}

	/// The face-side flank widens only to carry a message: resting width plus the reserved
	/// words and the gap between face and text. No words, no widening.
	///
	/// Reserved at the *longest* message the flank can carry rather than measured from the
	/// one in hand, so the silhouette is one number for the whole attempt. Sizing it to the
	/// sentence made the bar itself the thing that moved: each caption's length became a
	/// different silhouette, and the mark's neighbours grew and shrank under it. The text
	/// still hugs its own measure inside that slot, so short words look natural — it is only
	/// the black behind them that stops changing.
	private var earFaceFlankWidth: CGFloat {
		guard earCaption != nil else { return EarFlankMetrics.flank }
		return EarFlankMetrics.flank + 6 + EarFlankMetrics.maxCaptionWidth
	}

	private var isEarUnlocked: Bool {
		model.phase == .success || model.phase == .unlocked
	}

	private var earNotchHeight: CGFloat { notchInset + EarFlankMetrics.heightBump }

	private var earLock: some View {
		Image(systemName: isEarUnlocked ? "lock.open.fill" : "lock.fill")
			.accessibilityLabel(model.phase.markAccessibilityLabel)
			.font(.system(size: EarFlankMetrics.lockSize, weight: .semibold))
			.foregroundStyle(.white)
			.contentTransition(.symbolEffect(.replace))
	}

	private var earFace: some View {
		NotchFaceMark(phase: model.phase, usesNativeAnimation: model.usesNativeAnimation,
			colour: model.animationColour, active: model.isExpanded && !isCompactPhase)
			.frame(width: EarFlankMetrics.faceSize, height: EarFlankMetrics.faceSize)
	}

	private var earShape: RoundedRectangle {
		RoundedRectangle(cornerRadius: EarFlankMetrics.topRadius, style: .continuous)
	}

	/// The silhouette fill, honouring Style like the island does.
	@ViewBuilder
	private var earSilhouette: some View {
		switch model.style {
		case .normal:
			earShape.fill(.black)
		case .semiLiquidGlass:
			earShape
				.fill(.black.opacity(glassTint))
				.background { earShape.fill(.ultraThinMaterial) }
		case .liquidGlass:
			liquidSurface(earShape, outline: .rounded(EarFlankMetrics.topRadius))
		}
	}

	@ViewBuilder
	internal var earBody: some View {
		HStack(spacing: 0) {
			earLock
				.frame(width: EarFlankMetrics.flank, height: earNotchHeight)
			// The physical cutout itself: reserved space, never drawn over.
			Spacer(minLength: 0)
				.frame(width: cutoutWidth)
			// The mark keeps the same place whether or not there are words beside it.
			//
			// It sat centred in the captionless slot and *led* the row when there were
			// words, so the padding that centres it disappeared the moment a message
			// arrived and took the mark 12pt sideways with it. A rejection is the one thing
			// that brings words to this flank — `.scanning` and `.success` carry none — so
			// it was the rejected animation that jumped while the accepted one sat still.
			//
			// The inset below is exactly the centring the captionless branch gets for free,
			// stated rather than derived, so the two agree.
			if let caption = earCaption {
				HStack(spacing: 6) {
					earFace
						.padding(.leading, (EarFlankMetrics.flank - EarFlankMetrics.faceSize) / 2)
					Text(caption)
						.font(.system(size: 12, weight: .semibold))
						.foregroundStyle(.white)
						.lineLimit(1)
						.truncationMode(.tail)
						.frame(width: earMessageWidth)
						.accessibilityHidden(true)
				}
				.frame(width: earFaceFlankWidth, height: earNotchHeight, alignment: .leading)
				.transition(.opacity)
			} else {
				earFace
					.frame(width: EarFlankMetrics.flank, height: earNotchHeight)
			}
		}
		.padding(.horizontal, 4)
		.background { earSilhouette.glassEffectID("ear", in: panelGlass).glassEffectTransition(.identity) }
		// Only the face side grows, so matching clear space on the lock side keeps the
		// reserved gap centred on the camera instead of sliding left of it.
		.padding(.leading, earFaceFlankWidth - EarFlankMetrics.flank)
		.frame(height: earNotchHeight)
		.scaleEffect(expanded ? 1 : 0.94, anchor: .top)
		.opacity(expanded ? 1 : 0)
		.animation(reduceMotion ? nil : NotchAnimation.phase, value: earCaption ?? "")
		.animation(
			reduceMotion ? nil : (expanded ? NotchAnimation.expand : NotchAnimation.retract),
			value: "\(expanded)-\(earFaceFlankWidth)")
	}
}
