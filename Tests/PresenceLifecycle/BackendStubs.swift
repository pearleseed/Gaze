import Foundation

/// Minimal stubs for external types referenced by `Preferences.swift` and
/// `UnlockBackend.swift`, allowing `PresenceLifecycle` tests to compile and
/// test the real production `UnlockBackendKind`, `Preferences`, and
/// `UnlockExecutionPolicy` without pulling in Vision/CoreML/Keychain.
enum DetectionDistance: String, CaseIterable, Sendable {
	case close
	case standard
	case far
}

protocol FaceEmbedder: Sendable {
	var identifier: String { get }
}

private struct StubEmbedder: FaceEmbedder {
	let identifier = "stub"
}

enum Embedders {
	static func best() -> any FaceEmbedder { StubEmbedder() }
}

enum SpoofDetector {
	static let isAvailable = false
}

enum PasswordVault {
	static var isStale: Bool { false }
	static func containsPassword() throws -> Bool { false }
	static func password() throws -> String? { nil }
}
