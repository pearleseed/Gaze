import AppKit
import CoreGraphics
import GazeCore

package enum PasswordReplaySafety {
	private static let consentKey = "passwordReplayOptInV1"
	package static var isEnabled: Bool { isEnabled(in: .standard) }
	package static let explanation = "Automatic Mac unlocking is off. Enable Unlock my Mac in Gaze Settings to use face verification. Your Mac password and Touch ID remain available."

	package static func isEnabled(in defaults: UserDefaults) -> Bool {
		defaults.object(forKey: consentKey) as? Bool == true
	}

	package static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
		defaults.set(enabled, forKey: consentKey)
		if defaults === UserDefaults.standard {
			NotificationCenter.default.post(name: .gazePasswordReplaySafetyChanged, object: nil)
		}
	}

	package static func requireEnabled(in defaults: UserDefaults = .standard) throws {
		guard isEnabled(in: defaults) else { throw SafetyError.disabled }
	}

	private enum SafetyError: LocalizedError {
		case disabled
		var errorDescription: String? { PasswordReplaySafety.explanation }
	}
}

package struct LockScreenSubmissionBudget: Sendable {
	package private(set) var maySubmit = true

	package init() {}

	package mutating func reserve() -> Bool {
		guard maySubmit else { return false }
		maySubmit = false
		return true
	}

	package mutating func resetAfterVerifiedUnlock() {
		maySubmit = true
	}
}

package struct LockedConsoleSession: Equatable, Sendable {
	package let userID: UInt32
	package let identifier: String

	package init(userID: UInt32, identifier: String) {
		self.userID = userID
		self.identifier = identifier
	}

	package static func current() -> Self? {
		validated(CGSessionCopyCurrentDictionary() as? [String: Any], owner: geteuid())
	}

	package static func validated(_ values: [String: Any]?, owner: UInt32) -> Self? {
		guard let values,
			values["CGSSessionScreenIsLocked"] as? Bool == true,
			values[kCGSessionOnConsoleKey as String] as? Bool == true,
			values[kCGSessionLoginDoneKey as String] as? Bool == true,
			let userID = values[kCGSessionUserIDKey as String] as? UInt32,
			userID == owner,
			let identifier = values["CGSSessionUniqueSessionUUID"] as? String,
			UUID(uuidString: identifier) != nil
		else { return nil }
		return Self(userID: userID, identifier: identifier)
	}
}

@MainActor
package enum LockScreenPasswordSubmission {
	package enum SubmissionError: LocalizedError {
		case unsafeSession, disabled, permissionDenied, noPassword, verificationExpired

		package var errorDescription: String? {
			switch self {
			case .unsafeSession:
				"The locked console session changed or could not be verified. Password submission stopped."
			case .disabled: "Gaze is paused or password unlocking is disabled."
			case .permissionDenied: "Keyboard posting is not authorized. Check Gaze's Accessibility permission."
			case .noPassword: "No account password is stored. Save it in Settings or use macOS authentication."
			case .verificationExpired: "The face verification expired before password submission finished. Use macOS authentication."
			}
		}
	}

	package static func submit(
		readPassword: () throws -> String?,
		currentSession: () -> LockedConsoleSession?,
		isEnabled: () -> Bool,
		canPost: () -> Bool,
		isVerified: () -> Bool,
		executionPolicy: UnlockExecutionPolicy = .current,
		prepare: (String) throws -> [CGEvent] = { try Keystrokes.passwordEvents($0) },
		post: (CGEvent) -> Void
	) throws {
		try Task.checkCancellation()
		guard executionPolicy.permitsPasswordSubmission else { throw SubmissionError.disabled }
		guard let session = currentSession() else { throw SubmissionError.unsafeSession }

		func checkPermissionAndSession() throws {
			try Task.checkCancellation()
			guard isEnabled() else { throw SubmissionError.disabled }
			guard canPost() else { throw SubmissionError.permissionDenied }
			guard currentSession() == session else { throw SubmissionError.unsafeSession }
			guard isVerified() else { throw SubmissionError.verificationExpired }
		}

		try checkPermissionAndSession()
		guard let password = try readPassword() else { throw SubmissionError.noPassword }
		try checkPermissionAndSession()
		let events = try prepare(password)
		for event in events {
			try checkPermissionAndSession()
			post(event)
		}
	}
}
