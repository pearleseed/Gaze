import Foundation

package enum UnlockExecutionPolicy: Equatable, Sendable {
	case normal
	case uiReview
	case scanOnly

	package static var current: Self { Self(arguments: CommandLine.arguments) }

	package init(arguments: [String]) {
		if arguments.contains("--scan-only") {
			self = .scanOnly
		} else if arguments.contains("--ui-review") {
			self = .uiReview
		} else {
			self = .normal
		}
	}

	package var permitsPasswordSubmission: Bool { self == .normal }
	package var permitsAutomaticLocking: Bool { self == .normal }
	package var permitsLockObservation: Bool { self == .normal || self == .scanOnly }

	package func permitsAdminPromptApproval(passwordReplayEnabled _: Bool) -> Bool {
		self == .scanOnly || self == .normal
	}

	package func permitsScanning(passwordReplayEnabled: Bool, keystrokeSelected: Bool) -> Bool {
		self == .scanOnly || (self == .normal && passwordReplayEnabled && keystrokeSelected)
	}
}
