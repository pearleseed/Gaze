import GazeCore
import Observation
import SwiftUI

/// Live state for the lock screen panel.
///
/// The phase lives in an observable model rather than being passed as a plain value,
/// because the panel is hosted in an `NSHostingView` that outlives any single phase.
/// Replacing the hosting view's `rootView` on each change destroys the SwiftUI view's
/// identity, which resets its `@State` and leaves the transitions with nothing to animate
/// between — the symptom is a glyph that appears, sits still, and vanishes.
@Observable
@MainActor
package final class NotchCapsuleModel {
	package enum Phase: Equatable, Sendable {
		/// Screen is locked, nobody in frame. A padlock, no camera activity implied.
		case locked
		case scanning
		case notRecognised
		/// Gaze couldn't check at all: a camera that stopped, a missing model, a lockout,
		/// a changed password. Its own phase so the panel never says "Try again" about
		/// something trying again can't fix.
		case unavailable(String)
		/// Matched the enrolled face, but the anti-spoof model judged it a fake — a photo
		/// or a screen held to the camera. Its own phase, not `notRecognised`, because it
		/// is a different answer: "that is your face, but it isn't you here."
		case spoofRejected
		/// Recognised, and now being asked to prove they are present — blink, turn, nod.
		///
		/// Between the match and the password, and only when the user has asked for it. The
		/// object detector catches a device held in frame; this catches the case it cannot,
		/// a photograph filling the whole frame with no bezel to see. A photo cannot blink.
		///
		/// The prompt travels with the phase rather than being read from a model, because
		/// the panel is drawn by an `NSHostingView` in a different process context from the
		/// watcher that picks the action, and a shared observable across that boundary is a
		/// great deal of machinery for one short string.
		case challenge(prompt: String, symbol: String, hintX: CGFloat, hintY: CGFloat, pulses: Bool, isReturningToRest: Bool = false)
		/// The password has been submitted and macOS has not confirmed the unlock yet.
		/// Waiting, neutrally: the padlock stays closed and there is no tick.
		///
		/// A tick here would read as a completed unlock while the login window is still
		/// deciding. `.success` is autofill-only; confirmation arrives as `.unlocked`.
		case pending
		/// Autofill filled the password into a saved app. The tick.
		///
		/// The Mac unlock path never presents this between submission and confirmation —
		/// that gap is `.pending`. Collapsing the two announced an outcome the Mac had
		/// not confirmed yet.
		case success
		/// The Mac is actually open. The padlock lets go.
		///
		/// Separate from `pending` because they are separate events, and the gap between them
		/// is real: pending is this app saying "that was you, here is your password", and the
		/// padlock opening is the Mac agreeing. Collapsing the two meant the padlock opened
		/// while the login window was still deciding — announcing an outcome we had not been
		/// told yet.
		case unlocked

		/// Compact whenever the padlock is the thing being shown.
		///
		/// A panel that hangs open all the while the Mac is locked is a permanent lump
		/// under the notch; one that sits flush and grows when it has something to say is
		/// a status indicator.
		///
		/// Success and pending keep the panel open to carry the tick and the waiting words.
		/// Unlocked is back to resting: the panel is already on its way home and the
		/// padlock is the only thing left to say.
		package var isCompact: Bool { self == .locked || self == .unlocked }

		/// The words shown beneath the mark while waiting for macOS to confirm the unlock.
		package static let pendingCaption = "Waiting for macOS"
		/// Neutral waiting symbol: an hourglass, never a tick or an opening padlock.
		package static let pendingSymbol = "hourglass"
		/// The words shown when the face does not match, with a retry cue.
		package static let notRecognisedCaption = "Not recognised. Try again."
		/// The mark's own symbol for a miss, matching the Settings face glyph.
		package static let notRecognisedSymbol = "faceid"
		/// The words shown when the anti-spoof check refuses the attempt.
		///
		/// It does not say "photo": the detector looks for a phone, screen or print
		/// anywhere in frame, so a real face can be refused because of a monitor or a
		/// picture on the wall behind it. Naming a cause the app cannot be sure of
		/// accuses the owner of something they did not do. "Use your password" rather
		/// than "try again" because looking again will not clear it.
		package static let spoofRejectedCaption = "Face rejected. Use your password."
		/// A blocked-by-a-check symbol, rather than one naming a cause.
		package static let spoofRejectedSymbol = "exclamationmark.shield"
		/// The brief tick after Follow the light passes, so it is clear it worked.
		package static let movementDoneCaption = "Done"
		package static let movementDoneSymbol = "checkmark"

		/// The words the panel shows, where the phase carries its own.
		package var challengePrompt: String? {
			if case .challenge(let prompt, _, _, _, _, _) = self { return prompt }
			return nil
		}

		/// Every caption the panel can show: challenge words, the neutral pending
		/// message, or the two rejection captions. Other padlock-closed states
		/// carry no caption.
		package var captionText: String? {
			if let prompt = challengePrompt { return prompt }
			if case .pending = self { return Self.pendingCaption }
			if case .notRecognised = self { return Self.notRecognisedCaption }
			if case .spoofRejected = self { return Self.spoofRejectedCaption }
			if case .unavailable(let message) = self { return message }
			return nil
		}

		/// The symbol beside the caption, if the phase carries one.
		package var captionSymbol: String? {
			if case .challenge(_, let symbol, _, _, _, _) = self { return symbol }
			if case .pending = self { return Self.pendingSymbol }
			if case .notRecognised = self { return Self.notRecognisedSymbol }
			if case .spoofRejected = self { return Self.spoofRejectedSymbol }
			if case .unavailable = self { return "exclamationmark.triangle.fill" }
			return nil
		}

		/// An outward movement prompt with the gate's progress, in two-movement mode.
		///
		/// The first presentation reads "… · 1 of 2" and the second "… · 2 of 2", so a
		/// fresh prompt after a completed movement reads as progress rather than a reset.
		/// One-movement mode stays exactly as-is: with nothing to count, a suffix would
		/// be clutter. Return-to-rest prompts never pass through here — the animated
		/// return stays captionless by design.
		///
		/// Pure presentation: the gate keeps the count, and `reset()` clears it, so a
		/// reset can never leave a stale "2 of 2" behind — the next presentation is
		/// recomputed from the cleared gate.
		package static func outwardPrompt(_ prompt: String, completedActions: Int, requiredActions: Int) -> String {
			guard requiredActions == 2 else { return prompt }
			return "\(prompt) · \(completedActions + 1) of \(requiredActions)"
		}

		/// How the mark should move to demonstrate the action, if it should.
		package var challengeHint: (x: CGFloat, y: CGFloat, pulses: Bool)? {
			if case .challenge(_, _, let x, let y, let pulses, _) = self { return (x, y, pulses) }
			return nil
		}

		/// The action's own symbol, shown beside the words rather than instead of the face.
		package var challengeSymbol: String? {
			if case .challenge(_, let symbol, _, _, _, _) = self { return symbol }
			return nil
		}

		package var isReturningToRest: Bool {
			if case .challenge(_, _, _, _, _, let returning) = self { return returning }
			return false
		}

		/// What the mark in the panel announces to VoiceOver.
		///
		/// On the phase rather than on either mark, because there are two marks — the drawn
		/// head and the native unlock animation — and they must say the same thing. One
		/// statement of it is what stops them drifting.
		package var markAccessibilityLabel: String {
			switch self {
			case .challenge(let prompt, _, _, _, _, _): prompt
			case .scanning: "Looking for your face"
			case .pending: "Waiting for macOS"
			case .success: "Face verified"
			case .notRecognised: "Face not recognised. Try again."
			case .spoofRejected: "Face rejected. Use your password."
			case .unavailable(let message): message
			case .locked: "Locked"
			case .unlocked: "Unlocked"
			}
		}
	}

	package var phase: Phase = .scanning
	/// Deepen the tint when the wallpaper behind is light, or glass goes pale and the
	/// glyph disappears into it.
	package var lightBehind = false
	/// Mirrors `Preferences.notchStyle`, captured when the panel is shown.
	package var style: Preferences.NotchStyle = .normal
	/// Mirrors `Preferences.panelShape`, captured when the panel is shown.
	package var shape: Preferences.PanelShape = .attached
	/// Mirrors `Preferences.glyphPlacement`.
	package var glyphPlacement: Preferences.GlyphPlacement = .centred
	/// Mirrors `Preferences.nativeUnlockAnimation`, captured when the panel is shown.
	///
	/// Display only: it chooses which mark the panel draws, never whether Gaze checks a
	/// face or unlocks.
	package var usesNativeAnimation = true
	/// Mirrors `Preferences.unlockAnimationColour`, captured when the panel is shown.
	package var animationColour: Preferences.UnlockAnimationColour = .blue
	package var transparency: Double = 0.3
	/// The wallpaper behind the window, for drawing Liquid Glass on the lock screen where
	/// system glass has nothing to sample. Nil falls back to `.glassEffect`.
	package var backdrop: GlassBackdrop?
	/// Mirrors `Preferences.showNotchCaptions`, captured when the panel is shown.
	/// Display only: captions reserve space only when enabled.
	package var showsCaptions = true
	/// Drives the grow-out and retract-back. False collapses the panel to the notch's own
	/// height, where it is hidden behind the cutout.
	package var isExpanded = false

	package init() {}
}
