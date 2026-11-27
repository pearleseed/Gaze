import Foundation
import GazeCore
import GazeSecurity
import Testing

@Suite("Movement, Caption & Sensitivity Preferences")
@MainActor
struct MovementSettingsTests {
	private func requiresSendableIterable<T: Sendable>(
		_ type: T.Type
	) where T: CaseIterable, T: RawRepresentable, T.RawValue == Int {}

	@Test func movementCountContractAndResolution() {
		typealias Count = Preferences.UnlockMovementCount
		requiresSendableIterable(Count.self)

		#expect(Count.none.rawValue == 0)
		#expect(Count.one.rawValue == 1)
		#expect(Count.two.rawValue == 2)
		#expect(Count.allCases.count == 3)
		#expect(Count.allCases.allSatisfy { $0.rawValue >= 0 })

		#expect(Count.resolve(stored: nil) == .two)
		#expect(Count.resolve(stored: 0) == .none)
		#expect(Count.resolve(stored: -1) == .two)
		#expect(Count.resolve(stored: 3) == .two)
		#expect(Count.resolve(stored: 1) == .one)
		#expect(Count.resolve(stored: 2) == .two)
		for invalid: Any in [true, false, "1", 1.5, Double.nan, Double.infinity] {
			#expect(Count.resolve(stored: invalid) == .two)
		}

		#expect(Count.none.title == "No movement (less secure)")
		#expect(Count.one.title == "One movement")
		#expect(Count.two.title == "Two movements (recommended)")
	}

	@Test func preferencesPersistReloadAndFailSafeOnCorruptValues() throws {
		typealias Count = Preferences.UnlockMovementCount
		typealias Sensitivity = Preferences.RecognitionSensitivity

		let suite = "com.pearleseed.MovementSettingsTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		let preferences = Preferences(defaults: defaults)
		#expect(preferences.unlockMovementCount == .two)
		#expect(defaults.object(forKey: "unlockMovementCount") == nil)

		for backend in [UnlockBackendKind.none, .keystroke] {
			preferences.unlockBackend = backend
			for count in Count.allCases {
				preferences.unlockMovementCount = count
				#expect(defaults.integer(forKey: "unlockMovementCount") == count.rawValue)
				#expect(Preferences(defaults: defaults).unlockMovementCount == count)
			}
		}

		for invalid: Any in [-1, 3, true, "1", 1.5] {
			defaults.set(invalid, forKey: "unlockMovementCount")
			#expect(Preferences(defaults: defaults).unlockMovementCount == .two)
		}
		defaults.set(0, forKey: "unlockMovementCount")
		#expect(Preferences(defaults: defaults).unlockMovementCount == .none)

		#expect(Preferences(defaults: defaults).showNotchCaptions)
		#expect(defaults.object(forKey: "showNotchCaptions") == nil)
		for invalid: Any in [0, 2, "false", ["invalid"]] {
			defaults.set(invalid, forKey: "showNotchCaptions")
			#expect(Preferences(defaults: defaults).showNotchCaptions)
		}
		for enabled in [false, true, false] {
			let loaded = Preferences(defaults: defaults)
			let movementCount = loaded.unlockMovementCount
			loaded.showNotchCaptions = enabled
			let reloaded = Preferences(defaults: defaults)
			#expect(reloaded.showNotchCaptions == enabled)
			#expect(reloaded.unlockMovementCount == movementCount)
		}

		#expect(Sensitivity.relaxed.thresholdOffset == -0.08)
		#expect(Sensitivity.standard.thresholdOffset == 0)
		#expect(Sensitivity.strict.thresholdOffset == 0.05)
		#expect(Sensitivity.relaxed.title == "Relaxed")
		#expect(Sensitivity.standard.title == "Standard (recommended)")
		#expect(Sensitivity.strict.title == "Strict")
		#expect(preferences.recognitionSensitivity == .standard)
		for sensitivity in Sensitivity.allCases {
			preferences.recognitionSensitivity = sensitivity
			#expect(defaults.string(forKey: "recognitionSensitivity") == sensitivity.rawValue)
			#expect(Preferences(defaults: defaults).recognitionSensitivity == sensitivity)
		}
		defaults.set("paranoid", forKey: "recognitionSensitivity")
		#expect(Preferences(defaults: defaults).recognitionSensitivity == .standard)
	}

	@Test func challengeGateAcceptsConfiguredCountsAndFallsBackSafely() {
		var zeroGate = UnlockChallengeGate(requiredActions: 0)
		#expect(zeroGate.requiredActions == 0)
		#expect(zeroGate.isVerified)
		#expect(!zeroGate.isPresented)
		zeroGate.present(at: .now, frameID: 1)
		#expect(!zeroGate.isPresented)
		#expect(!zeroGate.expired(at: .now))

		for required in [1, 2] {
			let gate = UnlockChallengeGate(requiredActions: required)
			#expect(gate.requiredActions == required)
			#expect(!gate.isVerified)
		}
		#expect(UnlockChallengeGate(requiredActions: 3).requiredActions == 2)
	}
}
