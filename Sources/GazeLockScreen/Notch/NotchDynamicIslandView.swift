import GazeDesign
import SwiftUI

extension NotchCapsule {

	// MARK: - Dynamic Island

	/// A true floating capsule under the notch, on every Mac.
	internal var isDynamicIsland: Bool { model.shape == .dynamicIsland }

	private enum DynamicIslandMetrics {
		static let restingWidth: CGFloat = 126
		static let restingHeight: CGFloat = 37
		/// With something to say the island grows only a little taller and exactly as
		/// wide as its words: a Mac has no hardware island to hide in, so a large dark
		/// panel reads as empty space rather than as the island opening.
		static let activeHeight: CGFloat = 44
		static let successWidth: CGFloat = 170
		/// Below the notch's bottom edge — or below the safe area top with no notch.
		static let topGap: CGFloat = 6
		static let edgeInset: CGFloat = 12
		static let glyphSize: CGFloat = 15
		static let restingFaceSize: CGFloat = 24
		static let activeFaceSize: CGFloat = 30
		/// Past this total width the words truncate.
		static let maxWidth: CGFloat = 340
		/// One spring for every change of size, so width, height and radius move as one.
		static let morph = Animation.spring(response: 0.4, dampingFraction: 0.82)
		/// The small celebratory scale on success, up and back.
		static let successPulse = Animation.spring(response: 0.32, dampingFraction: 0.6)
	}

	// MARK: - Dynamic island body

	/// Whether the island has something to say. Locked and pending rest as the
	/// small capsule; scanning cannot tell whether a face is in frame yet, so it
	/// opens — "Looking for you" is something to say.
	private var isDynamicExpanded: Bool {
		switch model.phase {
		case .scanning, .challenge, .notRecognised, .spoofRejected, .unavailable: true
		case .locked, .pending, .success, .unlocked: false
		}
	}

	/// The island's celebratory state.
	///
	/// `.unlocked` joins it only when the native animation is on: the island's resting
	/// capsule is too small for the tick to read, so it grows for the unlock exactly as it
	/// already grows for `.success`. Without the clips, `.unlocked` stays the resting
	/// capsule it has always been.
	private var isDynamicSuccess: Bool {
		model.phase == .success
			|| (model.phase == .unlocked && model.usesNativeAnimation
				&& NativeUnlockAssets.isAvailable(colour: model.animationColour))
	}

	private var isDynamicUnlocked: Bool {
		model.phase == .success || model.phase == .unlocked
	}

	/// The open panel's headline. Challenge prompts arrive with their step count
	/// as a " · N of M" suffix (see `outwardPrompt`), which splits into a title
	/// and a step line; scanning and the rejections carry no step.
	///
	/// Ignores the caption setting on purpose: the island's whole job is to grow and carry
	/// these words, and with captions off it stayed a small capsule while scanning.
	private var dynamicTitle: String? {
		switch model.phase {
		case .challenge(let prompt, _, _, _, _, _) where !prompt.isEmpty:
			let parts = prompt.components(separatedBy: " · ")
			return parts.count > 1 ? parts.dropLast().joined(separator: " · ") : prompt
		case .scanning:
			return "Looking for you"
		case .notRecognised:
			return NotchCapsuleModel.Phase.notRecognisedCaption
		case .spoofRejected:
			return NotchCapsuleModel.Phase.spoofRejectedCaption
		case .unavailable(let message):
			return message
		case .success:
			return "Unlocked"
		default:
			return nil
		}
	}

	private var dynamicSubtitle: String? {
		if case .challenge(let prompt, _, _, _, _, _) = model.phase {
			let parts = prompt.components(separatedBy: " · ")
			if parts.count > 1, let step = parts.last, !step.isEmpty { return step }
		}
		return nil
	}

	private var dynamicHeight: CGFloat {
		isDynamicExpanded ? DynamicIslandMetrics.activeHeight : DynamicIslandMetrics.restingHeight
	}

	/// Always a number, measured from the words when there are any.
	///
	/// It used to be nil with words showing so the capsule could hug them. SwiftUI cannot
	/// interpolate between "hug" and a fixed width, so every open and close re-measured the
	/// text each frame and the morph stuttered. A measured width animates as one value.
	private var dynamicWidth: CGFloat {
		guard (isDynamicExpanded || isDynamicSuccess), let title = dynamicTitle else {
			return isDynamicSuccess ? DynamicIslandMetrics.successWidth : DynamicIslandMetrics.restingWidth
		}
		var words = Self.textWidth(title, size: 13, weight: .semibold)
		if let step = dynamicSubtitle { words += 6 + Self.textWidth(step, size: 12, weight: .medium) }
		words = min(words, DynamicIslandMetrics.maxWidth - 100)
		let chrome = DynamicIslandMetrics.edgeInset * 2 + 20 + DynamicIslandMetrics.activeFaceSize + 20
		// Success measures its word like any other title, with successWidth as the floor
		// rather than the fixed size — a fixed size would clip a wider future caption.
		let minimum = isDynamicSuccess ? DynamicIslandMetrics.successWidth : DynamicIslandMetrics.restingWidth
		return min(DynamicIslandMetrics.maxWidth, max(minimum, (words + chrome).rounded(.up)))
	}

	/// One key for the morph, so a single spring drives size and radius together.
	private var dynamicLayoutKey: String {
		"\(isDynamicExpanded)-\(isDynamicSuccess)-\(dynamicTitle ?? "")"
	}

	/// A capsule honouring Style, the way the ear pill did.
	@ViewBuilder
	private var dynamicSilhouette: some View {
		let shape = Capsule(style: .continuous)
		switch model.style {
		case .normal:
			shape.fill(.black)
		case .semiLiquidGlass:
			shape
				.fill(.black.opacity(glassTint))
				.background { shape.fill(.ultraThinMaterial) }
		case .liquidGlass:
			liquidSurface(shape, outline: .capsule)
		}
	}

	/// The glyph on the leading end: the movement's own symbol while a prompt is up,
	/// otherwise the lock, opening on success.
	private var dynamicGlyph: some View {
		Image(systemName: model.phase.challengeSymbol ?? dynamicLockSymbol)
			.accessibilityHidden(true)
			.font(.system(size: DynamicIslandMetrics.glyphSize, weight: .semibold))
			// Green only on success, as a checkmark in circle: the rest of the time
			// the glyph is a status mark, and colour there would spend the
			// confirmation colour before anything is confirmed.
			.foregroundStyle(isDynamicSuccess ? Theme.faceID : .white)
			.contentTransition(.symbolEffect(.replace))
			.frame(width: 20)
	}

	/// Success ends on a green checkmark in circle; every other state keeps the lock vocabulary.
	private var dynamicLockSymbol: String {
		if isDynamicSuccess { return "checkmark.circle.fill" }
		return isDynamicUnlocked ? "lock.open.fill" : "lock.fill"
	}

	/// One row for every state: glyph, words when there are any, companion. Nothing is
	/// swapped out between states — only the words come and go — so the companion's
	/// renderer is never torn down and rebuilt mid-animation, which is what made the
	/// morph stutter.
	internal var dynamicBody: some View {
		HStack(spacing: 10) {
			dynamicGlyph
			if (isDynamicExpanded || isDynamicSuccess), let title = dynamicTitle {
				HStack(spacing: 6) {
					Text(title)
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(.white)
					if let step = dynamicSubtitle {
						Text(step)
							.font(.system(size: 12, weight: .medium))
							.foregroundStyle(.white.opacity(0.55))
					}
				}
				.lineLimit(1)
				.truncationMode(.tail)
				// The width cap belongs on the words. Around the capsule it made the black as
				// wide as the cap even at rest.
				.frame(maxWidth: .infinity, alignment: .leading)
				.accessibilityHidden(true)
				// Slide plus opacity on the existing feedback timing: a scale here was a
				// second, differently timed motion inside the morph.
				.transition(
					.asymmetric(
						insertion: .move(edge: .bottom).combined(with: .opacity),
						removal: .move(edge: .top).combined(with: .opacity)))
			} else {
				Spacer(minLength: 0)
			}
			NotchFaceMark(phase: model.phase, usesNativeAnimation: model.usesNativeAnimation,
				colour: model.animationColour, active: model.isExpanded && !isCompactPhase)
				.frame(width: DynamicIslandMetrics.activeFaceSize, height: DynamicIslandMetrics.activeFaceSize)
				.scaleEffect(isDynamicExpanded ? 1
					: DynamicIslandMetrics.restingFaceSize / DynamicIslandMetrics.activeFaceSize)
		}
		.padding(.horizontal, DynamicIslandMetrics.edgeInset)
		.frame(width: dynamicWidth, height: dynamicHeight)
		.background { dynamicSilhouette.glassEffectID("dynamic", in: panelGlass).glassEffectTransition(.identity) }
		// Words arriving mid-morph stay inside the capsule instead of spilling past it.
		.clipShape(Capsule(style: .continuous))
		// Animate the whole island as one layer, so size, radius and contents stay in step.
		.geometryGroup()
		.scaleEffect(reduceMotion || !isDynamicSuccess ? 1 : 1.04)
		.animation(reduceMotion ? nil : DynamicIslandMetrics.successPulse, value: isDynamicSuccess)
		.animation(reduceMotion ? NotchAnimation.reduced : DynamicIslandMetrics.morph, value: dynamicLayoutKey)
		// The top edge stays put while the island grows downward and sideways.
		.padding(.top, notchInset + DynamicIslandMetrics.topGap)
		.scaleEffect(reduceMotion ? 1 : (expanded ? 1 : 0.6), anchor: .top)
		.opacity(expanded ? 1 : 0)
		// No animation on `expanded` here: the outer body already animates it, and a
		// second spring on the same value fought it over scale and opacity mid-morph.
	}
}
