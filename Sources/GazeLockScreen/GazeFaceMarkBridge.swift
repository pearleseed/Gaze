import GazeDesign
import SwiftUI

extension GazeFaceMotion {
	package init(phase: NotchCapsuleModel.Phase) {
		switch phase {
		case .locked, .unlocked, .pending: self = .resting
		case .scanning: self = .scanning
		case .success: self = .accepted
		case .notRecognised, .spoofRejected, .unavailable: self = .rejected
		case .challenge(_, let symbol, let horizontal, let vertical, _, _):
			// Look at the light: the head stays still, so the face must not demo a turn.
			// The light at the screen edge and the chevron carry the cue.
			if symbol == "eye.fill", horizontal != 0 { self = .resting }
			else if horizontal < 0 { self = .turnLeft }
			else if horizontal > 0 { self = .turnRight }
			else if vertical > 0 { self = .nod }
			else if symbol == "eye.fill" { self = .blink }
			else if symbol == "mouth.fill" { self = .openMouth }
			else if symbol == "viewfinder" { self = .returnToCenter }
			else if symbol == NotchCapsuleModel.Phase.movementDoneSymbol { self = .accepted }
			else { self = .resting }
		}
	}
}

package struct GazeFaceMark: View {
	package let phase: NotchCapsuleModel.Phase
	package var active: Bool

	package init(phase: NotchCapsuleModel.Phase, active: Bool = true) {
		self.phase = phase
		self.active = active
	}

	package var body: some View {
		GazeCompanionView(motion: GazeFaceMotion(phase: phase), active: active,
			runsWhileInactive: true, presentation: .notch)
		.scaleEffect(1.18)
		.accessibilityElement(children: .ignore)
		.accessibilityHidden(false)
		.accessibilityLabel(phase.markAccessibilityLabel)
	}
}
