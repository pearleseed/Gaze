import Foundation
import Testing

@Suite("Settings UX Structural & Accessibility Invariants")
struct SettingsUXInvariantTests {
	private static func settingsSources() throws -> String {
		let root = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let settingsDir = root.appendingPathComponent("Sources/GazeApp/Settings", isDirectory: true)
		let files = try FileManager.default.contentsOfDirectory(
			at: settingsDir,
			includingPropertiesForKeys: nil
		)
		.filter { $0.pathExtension == "swift" }
		.sorted { $0.lastPathComponent < $1.lastPathComponent }
		#expect(!files.isEmpty)
		return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
	}

	@Test func recognitionOnlyModeRetainedPasswordAndNoVaultRead() throws {
		let settings = try Self.settingsSources()
		#expect(settings.contains("Try Test Recognition below. Nothing runs on the lock screen in this mode."))
		#expect(!settings.contains("Recognise your face without entering a password."))
		#expect(settings.contains("if settings.unlockBackend == .none, hasStoredPassword {"))
		#expect(settings.contains("Gaze doesn’t use it to unlock in this mode."))
		#expect(settings.contains("private var retainedPasswordRow: some View {"))
		#expect(!settings.contains("PasswordVault.password"))
	}

	@Test func enrolledFaceActionsKeyboardFocusAndAccessibilityLabels() throws {
		let settings = try Self.settingsSources()
		#expect(!settings.contains("if hovering {"))
		#expect(settings.contains("hovering || isEditing || portraitFocused || removeFocused"))
		#expect(settings.contains(#"accessibilityLabel("Remove \(face.name)")"#))
		#expect(settings.contains(#"accessibilityLabel("Choose a photo for \(face.name)")"#))
		#expect(settings.contains("BiometricGate.authorize(.removeEnrollment)"))
		#expect(settings.contains(#"accessibilityAction(named: Text("Remove \(face.name)"), remove)"#))
		#expect(!settings.contains("if controlsVisible {"))
	}

	@Test func enrolledFaceAvatarPickerPopoverAndNativePresets() throws {
		let settings = try Self.settingsSources()
		#expect(settings.contains(".popover(isPresented: $showingAvatarPicker"))
		#expect(settings.contains("FaceAvatarPicker("))
		#expect(settings.contains("FaceAvatarView("))
		#expect(settings.contains("NSApp.orderFrontCharacterPalette(nil)"))
		#expect(settings.contains("pendingCharacterPalette"))
		#expect(settings.contains("Button(\"Use Monogram\")"))
		#expect(settings.contains(".onChange(of: currentAvatar.preset)"))
		#expect(!settings.contains("monogramDraft = capped"))
		#expect(settings.contains("Choose Photo…"))
		#expect(settings.contains("store.avatar(for: face.id)"))
		#expect(settings.contains("store.setAvatarPreset($0, for: face.id)"))
	}

	@Test func touchIDScopeAndDeliberatelyUnchangedControls() throws {
		let settings = try Self.settingsSources()
		#expect(settings.contains("Ask before removing a face or changing the stored password"))
		#expect(settings.contains("Adding a face always asks, even when this is off."))
		#expect(!settings.contains("Require Touch ID for changes here"))
		#expect(settings.contains("isEnabled: BiometricGate.isAvailable,"))
		#expect(settings.contains("isOn: $settings.touchIDFallback)"))

		#expect(settings.contains("Movements to unlock this Mac"))
		#expect(settings.contains("Lock when I walk away"))
		#expect(settings.contains("if !SpoofDetector.isAvailable { notes.append("))
		#expect(settings.contains("Button { settings.resume() } label: {"))
	}
}
