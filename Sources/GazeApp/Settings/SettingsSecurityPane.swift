import AppKit
import SwiftUI
import GazeCore
import GazeDesign
import GazeRecognition
import GazeSecurity

struct SettingsSecurityPane: View {
	@Bindable var settings: Preferences
	let cameraGranted: Bool
	let accessibilityGranted: Bool
	@Binding var inputMonitoringGranted: Bool
	@Binding var sudoInstalled: Bool
	@Binding var sudoError: SudoSetupFailure?
	@State private var sudoChangeInProgress = false
	let highlightedSection: String?
	let reviewAccessibility: () -> Void

	var body: some View {
		movementsSection.settingsDestination("movementsSection", highlightedSection: highlightedSection)
		securitySection.settingsDestination("securitySection", highlightedSection: highlightedSection)
		permissionsSection.settingsDestination("permissionsSection", highlightedSection: highlightedSection)
	}

	/// Permission status is refreshed by Settings when the window appears or Gaze becomes active.
	private var permissionsSection: some View {
		SettingsSection(
			title: "Permissions",
			info: "Gaze needs the camera to see you and Accessibility to type your password. Input Monitoring is optional and only lets Space try again."
		) {
			SettingRow(
				title: "Camera",
				detail: cameraGranted
					? "Allowed" : "Not allowed — Gaze can't see you",
				symbol: "camera.fill",
				symbolTint: cameraGranted ? nil : Theme.warning
			) {
				Button("Open Settings") {
					openPrivacySettings("Privacy_Camera")
				}
				.gazeButton()
				.fixedSize()
			}

			RowDivider(inset: 0)
			SettingRow(
				title: "Accessibility",
				detail: accessibilityGranted
					? "Allowed" : "Not allowed. If Gaze is already on, remove it and add it again.",
				symbol: "accessibility",
				symbolTint: accessibilityGranted ? nil : Theme.warning
			) {
				// Once granted there is nothing to review, so it matches the Camera row.
				if accessibilityGranted {
					Button("Open Settings") { openPrivacySettings("Privacy_Accessibility") }
						.gazeButton()
						.fixedSize()
				} else {
					Button("Review") { reviewAccessibility() }
						.gazeButton()
						.fixedSize()
				}
			}

			RowDivider(inset: 0)
			// Optional: without it everything works except Space to try again.
			SettingRow(
				title: "Input Monitoring",
				detail: inputMonitoringGranted
					? "Allowed. Press Space on the lock screen to try again."
					: "Optional. Lets you press Space on the lock screen to try again.",
				symbol: "keyboard"
			) {
				Button(inputMonitoringGranted ? "Open Settings" : "Allow…") {
					// The first ask shows macOS's own prompt; after that, only System
					// Settings can change it.
					if inputMonitoringGranted || !SpaceKeyMonitor.requestAccess() {
						openPrivacySettings("Privacy_ListenEvent")
					}
					inputMonitoringGranted = SpaceKeyMonitor.isAllowed
				}
				.gazeButton()
				.fixedSize()
			}
		}
	}

	private func openPrivacySettings(_ anchor: String) {
		guard
			let url = URL(
				string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
		else { return }
		NSWorkspace.shared.open(url)
	}

	/// What Gaze asks you to do before it unlocks, on its own tab: it made the old
	/// Security checks group the longest thing in Settings.
	private var movementsSection: some View {
		SettingsSection(title: "Movements",
			info: "Movement verification asks for a random action each time. Password and Touch ID remain available on the lock screen.") {
			VStack(spacing: 0) {
				SettingRow(
					title: "Movements to unlock this Mac",
					detail: "Two is recommended. One is quicker.",
					symbol: "figure.walk.motion"
				) {
					SettingsStepSlider(title: "Movements to unlock this Mac",
						values: Preferences.UnlockMovementCount.allCases,
						selection: $settings.unlockMovementCount,
						label: \.shortTitle)
				}
				if settings.unlockMovementCount != .none {
					RowDivider()
					// The choices sit on their own line under the title, lined up with the
					// row text: five of them beside a title crowded both.
					VStack(alignment: .leading, spacing: 0) {
						SettingRow(title: "Movements Gaze can ask for",
							detail: "Picked at random each time",
							symbol: "shuffle"
						) { EmptyView() }
						MovementChoices(disabled: $settings.disabledMovements)
							.padding(.leading, Theme.rowInset + 26 + 12)
							.padding(.bottom, 14)
					}
				}
				RowDivider()
				SettingRow(title: "Unlock on first match",
					detail: "Skip the short steady look. Choose for each movement setting.",
					symbol: "bolt"
				) {
					InstantUnlockChoices(settings: settings)
				}
				let instant = { _ = settings.instantUnlockRevision; return settings.instantUnlock(for: settings.unlockMovementCount) }()
				if settings.unlockMovementCount == .none {
					StatusLine(kind: .warning,
						message: instant
							? "With no movement and Unlock on first match, a good photo or video of you could unlock this Mac. The photo and screen check still runs."
							: "Without a movement, a good photo or video is more likely to get through. The photo and screen checks still run.")
				} else if instant {
					StatusLine(kind: .warning,
						message: "Unlock on first match makes a good photo or video of you more likely to get through. The movement is still asked for.")
				}
			}

			RowDivider()
			SettingRow(
				title: "Recognition sensitivity",
				detail: "Relaxed helps in dim rooms. Strict is harder to fool.",
				symbol: "slider.horizontal.3"
			) {
				SettingsStepSlider(title: "Recognition sensitivity",
					values: Preferences.RecognitionSensitivity.allCases,
					selection: $settings.recognitionSensitivity,
					label: \.shortTitle)
			}
		}
	}

	private var securitySection: some View {
		SettingsSection(title: "Security checks", footer: securityFooter,
			info: "Choose which checks Gaze requires before unlocking. Movement verification asks for a random action each time. Password and Touch ID remain available on the lock screen.") {
			if settings.unlockBackend != .keystroke {
				SettingToggle(
					title: "Only trust the built-in camera",
					detail: "Each face only works on the camera it was set up with",
					symbol: "camera.fill",
					isEnabled: settings.unlockBackend != .keystroke,
					isOn: Binding(get: { settings.unlockBackend == .keystroke || settings.requireBuiltInCamera },
						set: { settings.requireBuiltInCamera = $0 }))
				RowDivider()
			}

			VStack(spacing: 0) {
				SettingToggle(
					title: "Allow USB cameras",
					detail: "For clamshell mode. Each face only unlocks on the camera it was set up with",
					symbol: "web.camera",
					isOn: $settings.allowExternalCamera)
				if settings.allowExternalCamera {
					StatusLine(kind: .warning,
						message: "A USB device can pretend to be a camera and replay a video of you. Turn this on only if you use your Mac with the lid closed, then add your face again with that camera.")
				}
			}

			RowDivider()
			SettingRow(
				title: "Lock when I walk away",
				detail: "Checks for absence after 20 seconds without input",
				symbol: "figure.walk.departure"
			) {
				HStack(spacing: 8) {
					InfoButton(title: "How walk-away lock checks") {
						Text(
							"Opens the camera briefly after 20 seconds without keyboard or pointer input. "
								+ "Any face found counts as someone there, and the check ends."
						)
						Text(
							"While input stays idle, it checks again no more often than every 30 seconds. "
								+ "Any input restarts the 20-second wait."
						)
						Text(
							"Locks after four seconds of fresh no-face evidence. "
								+ "When an app keeps the display awake, checks pause."
						)
						Text(
							"Needs Camera and Accessibility access. If the camera cannot confirm absence, "
								+ "Gaze leaves the Mac unlocked. You can still lock it yourself."
						)
					}
					Toggle("Lock when I walk away", isOn: walkAwayBinding)
						.labelsHidden()
						.accessibilityLabel("Lock when I walk away")
						.accessibilityHint("Checks for absence after 20 seconds without input")
						.toggleStyle(.switch)
						.controlSize(.small)
						.tint(Theme.accent)
				}
			}
			if settings.walkAwayLock && walkAwayNeedsAttention {
				RowDivider(inset: 0)
				walkAwayNotice
			}

			if BiometricGate.isAvailable {
				RowDivider()
				// Titled by what the switch actually gates: `BiometricGate.authorize()`
				// (remove-enrolment, store/revoke password) honours it; `require()`
				// (adding a face, trusting an autofill app) always prompts regardless.
				// No-sensor Macs hide the row outright — a switch that can never fire
				// is not a setting — with the footer below saying why.
				SettingToggle(
					title: "Ask before removing a face or changing the stored password",
					detail: "Adding a face always asks, even when this is off.",
					// Pink because Apple's own Touch ID icon is pink, not because a fifth hue
					// was needed. Every tint in this window now points at a System Settings row
					// that uses the same one.
					symbol: "touchid",
					isEnabled: BiometricGate.isAvailable,
					isOn: $settings.touchIDFallback)
			}

			RowDivider()
			SettingToggle(
				title: "Approve admin prompts with your face",
				detail: "When macOS asks for your password to make a change, Gaze fills it in after a face check.\nNodding gives that app full control of your Mac. Gaze never fills prompts for scripts or Terminal.",
				symbol: "lock.shield",
				isOn: Binding(
					get: { settings.approveAdminPrompts },
					set: { on in
						guard on else { settings.approveAdminPrompts = false; return }
						// Turning it on always asks: it lets a face approve system changes.
						Task { @MainActor in
							if await BiometricGate.require(.approveAdminPrompts) { settings.approveAdminPrompts = true }
						}
					}))

			RowDivider()
			SettingToggle(
				title: "Approve sudo with your face",
				detail: sudoInstalled
					? "In Terminal, Gaze shows the command and asks you to nod."
					: "In Terminal, Gaze shows the command and asks you to nod. Installation requires administrator approval.",
				symbol: "terminal",
				isEnabled: !sudoChangeInProgress,
				isOn: Binding(
					get: { sudoInstalled },
					set: { on in
						guard !sudoChangeInProgress else { return }
						sudoChangeInProgress = true
						Task { @MainActor in
							defer { sudoChangeInProgress = false }
							if on { guard await BiometricGate.require(.approveSudo) else { return } }
							do {
								if on { try await SudoApproval.install() } else { try await SudoApproval.uninstall() }
								sudoError = nil
							} catch SudoApprovalError.cancelled {
								sudoError = nil
							} catch {
								sudoError = SudoSetupFailure(enabling: on, error: error)
							}
							sudoInstalled = SudoApproval.isInstalled
						}
					}))
			if let sudoError {
				StatusLine(kind: .error, message: sudoError.message)
				if let command = sudoError.terminalCommand {
					HStack(spacing: 6) {
						Button("Open Full Disk Access") {
							openPrivacySettings("Privacy_AllFiles")
						}
						.gazeButton()
						.fixedSize()
						Button("Copy Terminal Command") {
							NSPasteboard.general.clearContents()
							NSPasteboard.general.setString(command, forType: .string)
						}
						.gazeButton()
						.fixedSize()
					}
					.padding(.horizontal, Theme.rowInset)
					.padding(.bottom, 10)
				}
			}
		}
	}

	/// Only the caveats. Rows that work as expected need no sentence explaining that they do.
	///
	/// Nil rather than empty when there is nothing to say — an empty footer still reserved
	/// its leading and its line height, which left an unexplained gap under the group.
	private var securityFooter: String? {
		var notes: [String] = []
		if !SpoofDetector.isAvailable { notes.append("The anti-spoof model is missing, so Gaze won't unlock this Mac. Reinstall Gaze to restore it.") }
		if !BiometricGate.isAvailable { notes.append("This Mac has no Touch ID sensor.") }
		return notes.isEmpty ? nil : notes.joined(separator: " ")
	}

	/// Sync only the presence watcher; changing this switch must not restart unlock.
	private var walkAwayBinding: Binding<Bool> {
		Binding(
			get: { settings.walkAwayLock },
			set: {
				settings.walkAwayLock = $0
				AppServices.shared.syncPresenceWatcher()
			})
	}

	private var walkAwayNeedsAttention: Bool {
		!AppServices.executionPolicy.permitsAutomaticLocking || !cameraGranted || !accessibilityGranted
	}

	@ViewBuilder
	private var walkAwayNotice: some View {
		if !AppServices.executionPolicy.permitsAutomaticLocking {
			StatusLine(
				kind: .warning,
				message: "Automatic locking is disabled for this diagnostic session.")
		} else {
			VStack(alignment: .leading, spacing: 0) {
				StatusLine(kind: .warning, message: walkAwayPermissionMessage)
				HStack(spacing: 6) {
					if !cameraGranted {
						Button("Open Camera Settings") { openPrivacySettings("Privacy_Camera") }
							.gazeButton()
							.fixedSize()
					}
					if !accessibilityGranted {
						Button("Review Accessibility") { reviewAccessibility() }
							.gazeButton()
							.fixedSize()
					}
				}
				.padding(.horizontal, Theme.rowInset)
				.padding(.bottom, 10)
			}
		}
	}

	private var walkAwayPermissionMessage: String {
		switch (cameraGranted, accessibilityGranted) {
		case (false, false):
			return "Camera and Accessibility access are off, so walk-away lock can neither check nor lock."
		case (false, true):
			return "Camera access is off, so walk-away lock cannot check."
		case (true, false):
			return "Accessibility access is off, so walk-away lock cannot lock the Mac."
		case (true, true):
			return ""
		}
	}
}

struct SudoSetupFailure {
	let enabling: Bool
	let error: any Error

	var message: String {
		(enabling ? "Couldn’t turn on sudo approval. " : "Couldn’t turn off sudo approval. ") + error.localizedDescription
	}

	var terminalCommand: String? {
		guard let approvalError = error as? SudoApprovalError, case .pamWriteDenied(let command) = approvalError else {
			return nil
		}
		return command
	}
}
