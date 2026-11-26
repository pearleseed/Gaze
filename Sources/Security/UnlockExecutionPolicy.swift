import Foundation

enum UnlockExecutionPolicy: Equatable {
	case normal
	case uiReview
	case scanOnly

	static var current: Self { Self(arguments: CommandLine.arguments) }

	init(arguments: [String]) {
		if arguments.contains("--scan-only") {
			self = .scanOnly
		} else if arguments.contains("--ui-review") {
			self = .uiReview
		} else {
			self = .normal
		}
	}

	var permitsPasswordSubmission: Bool { self == .normal }
	var permitsAutomaticLocking: Bool { self == .normal }
	var permitsLockObservation: Bool { self == .normal || self == .scanOnly }

	func permitsAdminPromptApproval(passwordReplayEnabled _: Bool) -> Bool {
		self == .scanOnly || self == .normal
	}

	func permitsScanning(passwordReplayEnabled: Bool, keystrokeSelected: Bool) -> Bool {
		self == .scanOnly || (self == .normal && passwordReplayEnabled && keystrokeSelected)
	}
}
