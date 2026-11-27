import Foundation
import GazeCore
import GazeSecurity
import Testing

@Suite("Presence Lifecycle Policy & AppServices Wiring")
@MainActor
struct PresenceLifecycleTests {
	private static func repositoryRoot() throws -> URL {
		let root = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let packageSwift = root.appendingPathComponent("Package.swift")
		#expect(FileManager.default.fileExists(atPath: packageSwift.path))
		return root
	}

	@Test func executionPolicyAutomaticLockingAndAdminPromptRules() {
		#expect(UnlockExecutionPolicy.normal.permitsAutomaticLocking)
		#expect(!UnlockExecutionPolicy.scanOnly.permitsAutomaticLocking)
		#expect(!UnlockExecutionPolicy.uiReview.permitsAutomaticLocking)

		#expect(!UnlockExecutionPolicy(arguments: ["--scan-only"]).permitsAutomaticLocking)
		#expect(!UnlockExecutionPolicy(arguments: ["--ui-review"]).permitsAutomaticLocking)
		#expect(UnlockExecutionPolicy(arguments: []) == .normal)
		#expect(UnlockExecutionPolicy(arguments: []).permitsAutomaticLocking)

		#expect(UnlockExecutionPolicy(arguments: ["--browser-only"]) == .normal)
		#expect(UnlockExecutionPolicy(arguments: ["--browser-only"]).permitsAutomaticLocking)

		for replay in [false, true] {
			#expect(UnlockExecutionPolicy.normal.permitsAdminPromptApproval(passwordReplayEnabled: replay))
			#expect(UnlockExecutionPolicy.scanOnly.permitsAdminPromptApproval(passwordReplayEnabled: replay))
			#expect(!UnlockExecutionPolicy.uiReview.permitsAdminPromptApproval(passwordReplayEnabled: replay))
		}

		#expect(!UnlockExecutionPolicy(arguments: ["--scan-only", "--ui-review"]).permitsAutomaticLocking)
	}

	@Test func legacyAuthPluginBackendRemovedAndDefaultsFallBackSafely() throws {
		#expect(UnlockBackendKind(rawValue: "authPlugin") == nil)
		#expect(UnlockBackendKind.allCases == [.none, .keystroke])
		#expect(UnlockBackendKind.selectableCases == [.none, .keystroke])

		let suite = "com.pearleseed.PresenceLifecycleTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(Preferences(defaults: defaults).unlockBackend == .none)
		defaults.set("authPlugin", forKey: "unlockBackend")
		#expect(Preferences(defaults: defaults).unlockBackend == .none)
		defaults.set("unknownBackend", forKey: "unlockBackend")
		#expect(Preferences(defaults: defaults).unlockBackend == .none)
		defaults.set("keystroke", forKey: "unlockBackend")
		#expect(Preferences(defaults: defaults).unlockBackend == .keystroke)
		defaults.set("none", forKey: "unlockBackend")
		#expect(Preferences(defaults: defaults).unlockBackend == .none)
	}

	@Test func appServicesPresenceWatcherWiringInvariants() throws {
		let root = try Self.repositoryRoot()
		let appServices = try String(
			contentsOf: root.appendingPathComponent("Sources/GazeApp/AppServices.swift"),
			encoding: .utf8
		)
		let appDelegate = try String(
			contentsOf: root.appendingPathComponent("Sources/GazeApp/AppDelegate.swift"),
			encoding: .utf8
		)

		let syncStart = try #require(appServices.range(of: "func syncPresenceWatcher()"))
		let syncEnd = try #require(appServices.range(of: "\n\t}", range: syncStart.upperBound..<appServices.endIndex))
		let sync = String(appServices[syncStart.lowerBound..<syncEnd.lowerBound])

		#expect(sync.contains("permitsAutomaticLocking && Preferences.shared.walkAwayLock"))
		#expect(!sync.contains("PasswordReplaySafety"))
		#expect(!sync.contains("unlockBackend"))

		#expect(sync.contains("guard presenceWatcher == nil else { return }"))
		let firstCreate = try #require(sync.range(of: "PresenceWatcher(store:"))
		let lastCreate = try #require(sync.range(of: "PresenceWatcher(store:", options: .backwards))
		#expect(firstCreate.lowerBound == lastCreate.lowerBound)

		#expect(sync.contains("presenceWatcher?.stop()"))
		#expect(sync.contains("presenceWatcher = nil"))

		for forbidden in ["lockWatcher", "LockWatcher("] {
			#expect(!sync.contains(forbidden))
		}

		let triggerStart = try #require(appServices.range(of: "func startUnlockTrigger()"))
		#expect(triggerStart.lowerBound > syncEnd.lowerBound)
		let trigger = String(appServices[triggerStart.lowerBound...])
		let syncCall = try #require(trigger.range(of: "syncPresenceWatcher()"))

		for marker in [
			"if Self.executionPolicy == .scanOnly",
			"guard !Self.isUIReview else",
			"guard PasswordReplaySafety.isEnabled else",
			"switch Preferences.shared.unlockBackend",
		] {
			let markerRange = try #require(trigger.range(of: marker))
			#expect(syncCall.lowerBound < markerRange.lowerBound)
		}

		let outsideSync = String(appServices[..<syncStart.lowerBound]) + String(appServices[syncEnd.lowerBound...])
		#expect(!outsideSync.contains("PresenceWatcher(store:"))

		#expect(appDelegate.contains("AppServices.shared.startUnlockTrigger()"))
	}
}
