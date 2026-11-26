import Foundation
import GazeSecurity

/// Set by the app at launch so the Shortcuts action can reach the live check.
@MainActor
public enum FaceApprovalCenter {
	public enum Outcome: Sendable {
		case approved
		case failed
		case cancelled
		case unavailable
	}

	static var check: FaceApprovalCheck?

	public static func run(subject: String) async -> Outcome {
		guard let check else { return .unavailable }
		switch await check.run(subject: subject, isStillWanted: { true }, onApproved: { true }) {
		case .approved: return .approved
		case .failed: return .failed
		case .cancelled: return .cancelled
		case .unavailable: return .unavailable
		}
	}
}
