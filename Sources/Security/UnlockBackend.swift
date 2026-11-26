import AppKit
import Foundation
import os

enum UnlockBackendKind: String, CaseIterable, Sendable {
	/// Recognition runs, but nothing is unlocked. The safe default and a usable way to
	/// test enrolment without touching system authentication at all.
	case none
	/// The stored password is replayed into the login window as keystrokes.
	case keystroke

	/// Backends that are safe to offer in Settings.
	static let selectableCases: [UnlockBackendKind] = [.none, .keystroke]

	var title: String {
		switch self {
		case .none: return "Recognition only"
		case .keystroke: return "Unlock my Mac"
		}
	}

	/// Icon for the choice row.
	var symbol: String {
		switch self {
		case .none: return "eye.fill"
		case .keystroke: return "lock.open.fill"
		}
	}

	var detail: String {
		switch self {
		case .none:
			return "See recognition working without wiring it to anything."
		case .keystroke:
			return """
				Enters your password for you when you're recognised. Touch ID keeps \
				working. Your password is stored on this Mac in recoverable form, which is \
				what makes this possible.
				"""
		}
	}
}

protocol UnlockBackend: Sendable {
	var kind: UnlockBackendKind { get }
	/// Whether this backend can actually run right now.
	@MainActor func readiness() -> BackendReadiness
	/// Unlock the Mac. Only called after a match, a liveness pass and a lockout check.
	@MainActor func unlock() async throws
}

/// Refuses to let an embedder that cannot tell people apart drive real authentication.
///
/// Added after measurement, not theory: the first landmark embedder scored a completely
/// different person at 1.000, meaning it would have unlocked the Mac for anyone. A
/// recognition system that cannot reject is worse than no recognition system, because it
/// looks like security while providing none. Any embedder that hasn't demonstrated it can
/// discriminate is confined to recognition-only mode.
enum UnlockGuard {

	/// Embedders trusted to gate a real unlock.
	///
	/// Deliberately an allow-list. A new embedder is untrusted until someone has actually
	/// measured its false-accept behaviour on this machine and added it here.
	private static let trustedPrefixes = ["coreml:"]

	@MainActor
	static func embedderBlocker() -> BackendReadiness? {
		let identifier = Embedders.best().identifier
		guard !trustedPrefixes.contains(where: identifier.hasPrefix) else { return nil }
		return .unavailable(
			"The installed face matcher can't reliably tell people apart, so it isn't allowed to unlock "
				+ "your Mac. Install a recognition model at Resources/FaceEmbedding.mlpackage.")
	}
}

enum BackendReadiness: Equatable {
	case ready
	/// Usable once the user does something — grant a permission, set a password.
	case needsSetup(String)
	/// Cannot work on this machine or is not built yet.
	case unavailable(String)
}

// MARK: - No-op

struct NoUnlockBackend: UnlockBackend {
	let kind = UnlockBackendKind.none
	@MainActor func readiness() -> BackendReadiness { .ready }
	@MainActor func unlock() async throws {}
}

// MARK: - Password replay

/// Types the stored account password into the login window.
///
/// This is what Sapphire does, and it is the weaker of the two paths: the password must
/// be recoverable by this process to be typed, so anything that can run as this user and
/// read the vault can recover it. It is here because it works without modifying system
/// authentication, and because it keeps Touch ID intact.
struct KeystrokeUnlockBackend: UnlockBackend {
	let kind = UnlockBackendKind.keystroke

	private static let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "Keystroke")

	@MainActor func readiness() -> BackendReadiness {
		#if PRODUCT_CAPTURE
		if ProductCaptureDemo.isOn { return .ready }
		#endif
		guard PasswordReplaySafety.isEnabled else { return .unavailable(PasswordReplaySafety.explanation) }
		if let blocker = UnlockGuard.embedderBlocker() { return blocker }
		if !SpoofDetector.isAvailable {
			return .unavailable("Anti-spoof protection is enabled, but its model is unavailable. Use macOS authentication until the model is restored.")
		}
		do {
			guard try PasswordVault.containsPassword() else {
				return .needsSetup("Gaze needs your account password to unlock the Mac.")
			}
			guard !PasswordVault.isStale else {
				return .needsSetup("Your Mac password changed. Choose Change to save the new one, and Gaze will unlock again.")
			}
		} catch {
			return .unavailable("The saved account password could not be accessed. Check Keychain access and try again.")
		}
		guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
			return .needsSetup("Gaze needs Accessibility access to type your password.")
		}
		return .ready
	}

	@MainActor func unlock() async throws {
		throw UnlockError.verificationRequired
	}

	@MainActor func submitPassword(if stillVerified: () -> Bool, evidenceIsCurrent: () -> Bool) throws {
		try PasswordReplaySafety.requireEnabled()
		guard !PasswordVault.isStale else { throw UnlockError.noPassword }
		guard stillVerified() else { throw UnlockError.verificationRequired }
		try LockScreenPasswordSubmission.submit(
			readPassword: PasswordVault.password,
			currentSession: LockedConsoleSession.current,
			isEnabled: { PasswordReplaySafety.isEnabled && !Preferences.shared.isPaused && Preferences.shared.unlockBackend == .keystroke },
			canPost: { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
			isVerified: evidenceIsCurrent,
			prepare: {
				guard stillVerified() else { throw UnlockError.verificationRequired }
				// A Space pressed to retry sits in the password field; clear it first
				// so it isn't prepended to the password.
				return try Keystrokes.clearFieldEvents() + Keystrokes.passwordEvents($0)
			},
			post: { $0.post(tap: .cghidEventTap) })
		Self.logger.notice("Password events posted; awaiting macOS screen-unlock confirmation.")
	}
}

enum UnlockError: LocalizedError {
	case verificationRequired
	case noPassword
	case eventSourceUnavailable

	var errorDescription: String? {
		switch self {
		case .verificationRequired:
			return "A fresh, uninterrupted face check and movement response are required. Use macOS authentication."
		case .noPassword:
			return "No account password is stored."
		case .eventSourceUnavailable:
			return "Could not post keyboard events. Check Accessibility access."
		}
	}
}
