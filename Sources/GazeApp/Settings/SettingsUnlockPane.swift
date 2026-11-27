import AppKit
import SwiftUI
import GazeCore
import GazeDesign
import GazeLockScreen
import GazeRecognition
import GazeSecurity

/// Retains input and validation feedback while the Settings window changes panes.
struct SettingsUnlockForm {
	var passwordEntry = ""
	var passwordError: String?
	var lockoutPassword = ""
	var lockoutError: String?
}

struct SettingsUnlockPane: View {
	private static let relative: RelativeDateTimeFormatter = {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .full
		return formatter
	}()

	let store: FaceEnrollmentStore
	let lockout: LockoutManager
	@Bindable var settings: Preferences
	let isPaused: Bool
	let cameraGranted: Bool
	let accessibilityGranted: Bool
	@Binding var hasStoredPassword: Bool
	@Binding var form: SettingsUnlockForm
	let highlightedSection: String?
	let openSetup: (SetupStep) -> Void
	let revealSettingsSection: (String) -> Void

	@Environment(\.openWindow) private var openWindow
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		if lockout.isLockedOut { lockoutSection }
		hero.settingsDestination("hero", highlightedSection: highlightedSection)
		if store.isEnrolled { manageSection }
		unlockSection.settingsDestination("unlockSection", highlightedSection: highlightedSection)
		UnlockAttemptsSection().settingsDestination("unlockAttemptsSection", highlightedSection: highlightedSection)
	}

	// MARK: - Overview

	/// The glyph, the state, and the two things you can do about it.
	private var hero: some View {
		SettingsSection {
			// Laid out sideways, not as a centred stack.
			//
			// Centred, the glyph and its two buttons left a column of empty card either
			// side and the pane opened on a mostly blank box. A status row reads as part of
			// the settings rather than as a splash screen.
			HStack(spacing: 14) {
				Image(nsImage: GazeBrand.appIcon)
					.resizable()
					.interpolation(.high)
					.frame(width: 42, height: 42)
					.accessibilityHidden(true)

				VStack(alignment: .leading, spacing: 3) {
					Text(heroTitle)
						.font(Typography.heroTitle)
						.foregroundStyle(Theme.label)
					Text(heroDetail)
						.font(Typography.detail)
						.foregroundStyle(Theme.secondaryLabel)
						.fixedSize(horizontal: false, vertical: true)
				}

				Spacer(minLength: 8)

				// Equal widths.
				//
				// Two right-aligned buttons whose labels differ in length — "Set Up Again"
				// over "Test Recognition" — left a ragged left edge between them. Matching
				// their widths is what makes them read as a pair.
				VStack(alignment: .trailing, spacing: 6) {
					if isPaused {
						Button { settings.resume() } label: {
							Text("Resume Gaze").frame(maxWidth: .infinity)
						}
						.gazeButton(.primary, size: .large)
					}
					if store.isEnrolled, !cameraGranted {
						Button { revealSettingsSection("permissionsSection") } label: {
							Text("Review Permissions").frame(maxWidth: .infinity)
						}
						.gazeButton(.primary, size: .large)
					} else if store.isEnrolled, !isPaused, PasswordReplaySafety.isEnabled,
						settings.unlockBackend != .none, readinessProblem != nil {
						Button {
							revealSettingsSection(accessibilityGranted ? "unlockSection" : "permissionsSection")
						} label: {
							Text("Review Setup").frame(maxWidth: .infinity)
						}
						.gazeButton(.primary, size: .large)
					} else if !store.isEnrolled {
						Button {
							SetupRequest.beginOnboarding()
							AppActivation.bringToFront()
							openWindow(id: "enrollment")
						} label: {
							Text("Set Up Gaze")
								.frame(maxWidth: .infinity)
						}
						.gazeButton(.primary, size: .large)
						.disabled(!store.canAddFace)
						.help(store.canAddFace ? "Add your face to unlock this Mac" : "Remove an enrolled face before adding another")
					}

					if store.isEnrolled {
						Button {
							AppActivation.bringToFront()
							openWindow(id: "test")
						} label: {
							Text("Test Recognition").frame(maxWidth: .infinity)
						}
						.gazeButton(size: .large)
					}
				}
				.frame(width: 168)
			}
			.padding(.horizontal, Theme.rowInset)
			.padding(.vertical, 14)
		}
	}

	private var heroTitle: String {
		if lockout.isLockedOut { return "Gaze is locked out" }
		if !store.isEnrolled { return "Set up Gaze" }
		if isPaused { return "Gaze is paused" }
		if !cameraGranted { return "Camera access needed" }
		if !PasswordReplaySafety.isEnabled { return "Mac unlocking is off" }
		if settings.unlockBackend == .none { return "Recognition only" }
		if readinessProblem != nil { return "Unlock needs attention" }
		return "Gaze is ready"
	}

	private var heroDetail: String {
		if lockout.isLockedOut { return "Enter your account password below to enable Gaze again." }
		if store.isCorrupted { return "Your enrolled face couldn’t be read. Enroll it again." }
		if !store.isEnrolled { return "Add your face to get started." }
		if isPaused, let until = settings.pausedUntil {
			return "Face recognition resumes at \(until.formatted(date: .omitted, time: .shortened)). You can resume it sooner here."
		}
		if !cameraGranted { return "Allow the camera so Gaze can recognise you." }
		if !PasswordReplaySafety.isEnabled { return "Enable Unlock my Mac to use face verification. Your password and Touch ID remain available." }
		if settings.unlockBackend == .none { return "Try Test Recognition below. Nothing runs on the lock screen in this mode." }
		if let problem = readinessProblem { return problem.message }
		return store.faces.count == 1 ? "Your face can unlock this Mac." : "Your enrolled faces can unlock this Mac."
	}

	/// The enrolled faces, one row each.
	///
	/// A list rather than a single "Remove enrolled face" button, because there can
	/// be several now. The footer is the important part: every face here opens
	/// *this* account with *this* password, so a second face is not a second user —
	/// it is giving somebody your login. That has to be said where faces are added,
	/// not buried in a document nobody opens.
	private var manageSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(store.faces.count == 1 ? "Enrolled face" : "Enrolled faces")
				.font(Typography.groupTitle)
				.foregroundStyle(Theme.secondaryLabel)
				.padding(.horizontal, 4)
			if !store.faces.isEmpty, !store.anyEnabled {
				Text(FaceEnrollmentStore.allFacesOffMessage)
					.font(Typography.detail)
					.foregroundStyle(Theme.secondaryLabel)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.horizontal, 4)
			}
			// Tiles in a row, the way Touch ID & Password lists fingerprints.
			//
			// Apple has already answered this exact question — several enrolments of
			// the same biometric, each named, added and removed — and the answer is
			// not a list of rows. A tile is the size of the thing it represents, the
			// name sits under it where a name belongs, and adding one is a tile in the
			// same row rather than a button somewhere else in the pane.
			HStack(alignment: .top, spacing: 12) {
				ForEach(store.faces) { face in
					// Touched so the tile redraws when a picture is chosen.
					//
					// Portraits live on disk rather than on `face`, and `portrait(for:)` is
					// a method, so calling it observes nothing — without this read the tile
					// would keep its initials until something else invalidated the body.
					// It was written as `portraitRevision >= 0 ? … : nil`, which did perform
					// the read but is unsigned and therefore always true, leaving a dead
					// branch the compiler rightly complained about.
					let _ = store.portraitRevision
					FaceTile(
						face: face,
						avatar: store.avatar(for: face.id),
						isEnabled: Binding(
							get: { store.faces.first(where: { $0.id == face.id })?.isEnabled ?? face.isEnabled },
							set: { enabled in
								Task {
									// Switching off only narrows who can unlock, so it
									// needs no check. Switching on widens it again, so
									// it goes through the same confirmation as removing
									// a face. The store is untouched when the prompt is
									// cancelled, and the switch reads back from the
									// store, so it settles back on its own.
									if enabled {
										guard await BiometricGate.authorize(.removeEnrollment) else { return }
									}
									store.setEnabled(face.id, enabled)
								}
							}),
						rename: { store.rename(face.id, to: $0) },
						setPortrait: { store.setPortrait($0, for: face.id) },
						setAvatarPreset: { store.setAvatarPreset($0, for: face.id) },
						remove: {
							Task {
								guard await BiometricGate.authorize(.removeEnrollment) else { return }
								store.remove(face.id)
							}
						})
				}

				if store.canAddFace {
					AddFaceTile {
						SetupRequest.begin()
						AppActivation.bringToFront()
						openWindow(id: "enrollment")
					}
				}

				Spacer(minLength: 0)
			}
			.frame(maxWidth: .infinity)
			.padding(.horizontal, Theme.rowInset)
			.padding(.vertical, 8)
			if !manageFooter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				Text(manageFooter)
					.font(Typography.detail)
					.foregroundStyle(Theme.secondaryLabel)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.horizontal, 4)
			}
		}
	}

	private var manageFooter: String {
		var lines: [String] = []
		if store.faces.count > 1 {
			lines.append(
				"Any of these faces unlocks this Mac with your password. "
					+ "They are not separate accounts.")
		}
		if !store.canAddFace {
			lines.append("Gaze holds up to \(FaceEnrollmentStore.maximumFaces) faces.")
		}
		if store.embedder.identifier.hasPrefix("landmark") {
			lines.append(
				"No recognition model is installed, so Gaze is matching face geometry only. "
					+ "That tells you from a stranger but is much weaker than a trained model.")
		}
		return lines.joined(separator: " ")
	}

	// MARK: - Lockout

	private var lockoutSection: some View {
		SettingsSection(
			title: "Locked out",
			footer: "Gaze is disabled after \(LockoutManager.maxAttempts) failed attempts."
		) {
			VStack(spacing: 0) {
				SettingRow(
					title: "Account password",
					symbol: "exclamationmark.lock.fill", symbolTint: Theme.danger
				) {
					HStack(spacing: 6) {
						SettingsField(placeholder: "Required", text: $form.lockoutPassword)
							.frame(width: 140)
							.onChange(of: form.lockoutPassword) { _, value in
								if !value.isEmpty { form.lockoutError = nil }
							}
						Button("Unlock") { clearLockout() }
							.gazeButton()
							.disabled(form.lockoutPassword.isEmpty)
					}
				}
				if let lockoutError = form.lockoutError {
					StatusLine(kind: .error, message: lockoutError)
				}
			}
		}
	}

	// MARK: - Unlocking

	private var unlockSection: some View {
		SettingsSection(title: "Unlocking", info: unlockInfo) {
			SettingToggle(title: "Unlock my Mac",
				detail: !PasswordReplaySafety.isEnabled ? "Off — your Mac stays locked" : settings.unlockBackend == .keystroke
					? "Use face recognition on the lock screen"
					: "Off — your Mac stays locked",
				portrait: GazeBrand.toolbarIcon(dark: (settings.appTheme.colorScheme ?? colorScheme) == .dark),
				isOn: Binding(get: { PasswordReplaySafety.isEnabled && settings.unlockBackend == .keystroke },
					set: { unlockBinding.wrappedValue = $0 ? .keystroke : .none }))
				.disabled(AppServices.isUIReview && !ProductCaptureDemo.isOn)

			if settings.unlockBackend == .keystroke {
				RowDivider()
				passwordRow
			}

			// A password stored under "Unlock my Mac" survives a step down to
			// recognition-only mode: switching modes never touches the vault. Say so
			// where it applies, with the same Change / Revoke actions — reusing them,
			// not re-enabling unlock. Gated on the `hasStoredPassword` state (re-read
			// whenever this window comes forward), never on a vault read at draw time.
			if settings.unlockBackend == .none, hasStoredPassword {
				RowDivider()
				retainedPasswordRow
			}

			RowDivider()
			SettingToggle(
				title: "Light up the screen when it’s dark",
				detail: "Turns up the brightness so the camera can see you",
				symbol: "sun.max",
				isOn: $settings.screenGlowInDark)

			RowDivider()
			SettingToggle(
				title: "Unlock with a mask",
				detail: maskUnlockAvailable
					? "Unlock while wearing a mask or glasses"
					: "Scan your face again to use this",
				symbol: "facemask.fill",
				isEnabled: maskUnlockAvailable,
				isOn: $settings.unlockWithMask)

			RowDivider()
			SettingRow(
				title: "Detection distance",
				detail: "How far away Gaze can recognise you",
				symbol: "ruler"
			) {
				SettingsStepSlider(title: "Detection distance",
					values: DetectionDistance.allCases,
					selection: $settings.detectionDistance,
					label: \.title)
			}

			if let problem = readinessProblem, PasswordReplaySafety.isEnabled {
				RowDivider(inset: 0)
				StatusLine(kind: problem.kind, message: problem.message)
			}
		}
	}

	private var unlockBinding: Binding<UnlockBackendKind> {
		Binding(
			get: { settings.unlockBackend },
			set: {
				guard !AppServices.isUIReview else { return }
				PasswordReplaySafety.setEnabled($0 == .keystroke)
				settings.unlockBackend = $0
				// Apply immediately rather than at next launch.
				AppServices.shared.startUnlockTrigger()
			})
	}

	/// Whether any switched-on face can unlock with a mask: only faces enrolled
	/// with upper-face prints can.
	private var maskUnlockAvailable: Bool {
		store.faces.contains { $0.isEnabled && !$0.upperPrints.isEmpty }
	}

	private var unlockInfo: String {
		"When enabled, Gaze enters your stored account password after verification. Password and Touch ID remain available. "
			+ "The password is stored on this Mac in recoverable form so Gaze can type it. Turning this off does not delete the stored password; use Revoke to remove it. "
			+ "Use Test Recognition to practice without unlocking anything."
	}

	private var capsuleOutcomeLine: String {
		guard let capsule = NotchCapsuleController.lastBuildOutcome else { return "Not built yet" }
		return capsule.message + " (" + Self.relative.localizedString(for: capsule.at, relativeTo: Date()) + ")"
	}

	/// The readiness line, but only when there is something wrong with it.
	///
	/// A green "Ready." sitting permanently in the window is noise: the state it reports is
	/// the state the user already expects.
	private var readinessProblem: (kind: StatusLine.Kind, message: String)? {
		let backend: UnlockBackend =
			switch settings.unlockBackend {
			case .none: NoUnlockBackend()
			case .keystroke: KeystrokeUnlockBackend()
			}

		switch backend.readiness() {
		case .ready: return nil
		case .needsSetup(let message): return (.warning, message)
		case .unavailable(let message): return (.error, message)
		}
	}

	/// A stored password kept while recognition-only mode is selected.
	///
	/// Same state and same actions as the stored branch of `passwordRow` (Change
	/// opens the setup screen that verifies before saving; Revoke clears the vault
	/// through the existing `authorize(.storePassword)` path). Nothing here flips
	/// the backend back to keystroke, so automatic unlock stays off.
	private var retainedPasswordRow: some View {
		VStack(spacing: 0) {
			SettingRow(
				title: "Account password",
				detail: "Stored earlier. Gaze doesn’t use it to unlock in this mode.",
				symbol: "key.fill"
			) {
				HStack(spacing: 6) {
					Label("Stored", systemImage: "checkmark.circle.fill")
						.font(.system(.callout, weight: .medium))
						.foregroundStyle(Theme.faceID)
					Button("Change") { openSetup(.password) }
						.gazeButton()
						.fixedSize()
					Button("Revoke", role: .destructive) { revokePassword() }
						.gazeButton()
						.fixedSize()
				}
			}
			if let passwordError = form.passwordError {
				StatusLine(kind: .error, message: passwordError)
			}
		}
	}

	private var passwordRow: some View {
		VStack(spacing: 0) {
			SettingRow(
				title: "Account password",
				detail: hasStoredPassword
					? "Encrypted with a key from this Mac's Secure Enclave"
					: "Checked against your account before it's stored",
				symbol: "key.fill"
			) {
				HStack(spacing: 6) {
					// Once it's stored there's nothing to type — the field goes away and a
					// Revoke replaces Store. Leaving an editable field sitting there after
					// the password is saved was the confusing part (Jis' note): it looked
					// unsaved. Revoke clears it and brings the field back.
					if hasStoredPassword {
						Label("Stored", systemImage: "checkmark.circle.fill")
							.font(.system(.callout, weight: .medium))
							.foregroundStyle(Theme.faceID)
						// Change, not just Revoke.
						//
						// Revoke was the only way to a stored password, so changing one meant
						// deleting it first and typing the new one into a settings row with no
						// verification screen around it — and leaving the Mac with no stored
						// password in between. This opens the setup screen built for the job,
						// which checks the password against the account before saving it.
						Button("Change") { openSetup(.password) }
							.gazeButton()
							.fixedSize()
						Button("Revoke", role: .destructive) { revokePassword() }
							.gazeButton()
							.fixedSize()
					} else {
						SettingsField(placeholder: "Required", text: $form.passwordEntry)
							.frame(width: 140)
						Button("Store") { storePassword() }
							.gazeButton()
							.disabled(form.passwordEntry.isEmpty)
							.fixedSize()
					}

					// The answer where the question gets asked.
					//
					// "How is my password stored?" is the first thing anyone security-minded
					// wants to know, and it was only answered in a file on GitHub. It belongs
					// at the field you type the password into, at the moment you are deciding
					// whether to.
					InfoButton(title: "How your password is stored") {
						Text(
							"It's encrypted with a key generated inside this Mac's Secure "
								+ "Enclave, which never leaves it. Copied to another Mac, the "
								+ "stored file is useless."
						)
						Text(
							"It is not hashed. The app has to reproduce your exact password in "
								+ "order to type it, so it keeps something it can decrypt — and "
								+ "anything running as your user account could decrypt it too. "
								+ "Your face decides when it gets typed; it isn't part of the "
								+ "encryption."
						)
						Text(
							"\"Just recognise me\" does not use an account password to unlock your Mac. "
								+ "Switching modes does not delete an existing password. Use Revoke and "
								+ "check that removal succeeds; saved autofill passwords are separate."
						)
					}
				}
			}
			if let passwordError = form.passwordError {
				StatusLine(kind: .error, message: passwordError)
			}
		}
	}

	// MARK: - Actions

	private func storePassword() {
		Task {
			guard await BiometricGate.authorize(.storePassword) else { return }
			do {
				if try PasswordVault.store(form.passwordEntry) {
					form.passwordEntry = ""
					form.passwordError = nil
					hasStoredPassword = true
				} else {
					form.passwordError = "That password didn't match your account."
				}
			} catch {
				form.passwordError = error.localizedDescription
			}
		}
	}

	/// Clear the stored password. Brings the entry field (and Store) back, so it reads as
	/// a toggle between "stored" and "not stored" rather than a one-way door.
	private func revokePassword() {
		Task {
			guard await BiometricGate.authorize(.storePassword) else { return }
			do {
				try PasswordVault.remove()
				form.passwordEntry = ""
				form.passwordError = nil
				hasStoredPassword = false
			} catch {
				form.passwordError = error.localizedDescription
			}
		}
	}

	private func clearLockout() {
		if PasswordVault.verify(form.lockoutPassword) {
			lockout.clearAfterPasswordAuth()
			form.lockoutError = nil
			form.lockoutPassword = ""
		} else {
			form.lockoutPassword = ""
			form.lockoutError = "That password didn’t match. Try again."
		}
	}
}
