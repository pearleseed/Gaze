import AppKit
import AVFoundation
import GazeCore
import GazeRecognition
import GazeSecurity
import Observation
import SwiftUI

/// Whether the menu bar icon is currently shown, following `showsMenuBarIcon`.
///
/// The `MenuBarExtra` scene above exists only while this is true, so flipping the
/// Settings switch removes or re-adds the icon without relaunching. A shared object
/// rather than `@State` on the App: nothing else can reach into the App struct to
/// flip it when the preference changes, and `applicationShouldHandleReopen` reads
/// the same value outside any view.
@Observable
@MainActor
final class MenuBarVisibility {
	static let shared = MenuBarVisibility()

	/// Publishes only real changes. SwiftUI writes the `isInserted` binding back
	/// while it rebuilds scenes, and unconditional mutation announces every write,
	/// even an equal one: that rebuilt the App body, which wrote the binding again,
	/// until opening Settings overflowed the stack and Gaze crashed.
	var isVisible: Bool {
		get { visible }
		set {
			guard newValue != visible else { return }
			visible = newValue
		}
	}

	private var visible = Preferences.shared.showsMenuBarIcon

	@ObservationIgnored private var observer: NSObjectProtocol?

	private init() {
		observer = NotificationCenter.default.addObserver(
			forName: .gazeMenuBarVisibilityChanged, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.isVisible = Preferences.shared.showsMenuBarIcon
			}
		}
	}
}

/// Stores the Settings-opening closure wherever a live view holds `openWindow`.
///
/// On both the menu bar label and the Settings window itself: with the icon hidden
/// there is no label, and reopening Gaze (Spotlight, Finder, Dock) must still open
/// Settings rather than silently doing nothing.
struct SettingsOpenerSetup: View {
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		Color.clear
			.frame(width: 0, height: 0)
			.accessibilityHidden(true)
			.onAppear {
				AppActivation.openSettings = {
					AppActivation.bringToFront(userInitiated: true)
					openWindow(id: "settings")
				}
				SettingsNavigator.shared.presentSettings = AppActivation.openSettings
			}
	}
}

struct GazeStatusItemLabel: View {
	var body: some View {
		Image(nsImage: GazeBrand.menuBarIcon)
			.renderingMode(.template)
			.accessibilityLabel("Gaze")
			.background(SettingsOpenerSetup())
	}
}

package struct MenuBarStatusSnapshot: Equatable, Sendable {
	package let title: String
	package let opensSettings: Bool

	package init(title: String, opensSettings: Bool) {
		self.title = title
		self.opensSettings = opensSettings
	}
}

@MainActor
package enum MenuBarStatusModel {
	/// Just the time, in whatever form this Mac writes times. Built once — a
	/// `DateFormatter` per menu redraw is a surprising amount of work for six characters.
	private static let clock: DateFormatter = {
		let formatter = DateFormatter()
		formatter.timeStyle = .short
		formatter.dateStyle = .none
		return formatter
	}()

	/// Evaluates the menu bar status row in a single pass, calling `readiness` at most once.
	package static func evaluate(
		executionPolicy: UnlockExecutionPolicy,
		isLockedOut: Bool,
		isEnrolled: Bool,
		isPaused: Bool,
		pausedUntil: Date?,
		cameraAuthorized: Bool,
		passwordReplayEnabled: Bool,
		unlockBackend: UnlockBackendKind,
		readiness: () -> BackendReadiness
	) -> MenuBarStatusSnapshot {
		switch executionPolicy {
		case .uiReview:
			return MenuBarStatusSnapshot(title: "UI review — unlocking is off", opensSettings: false)
		case .scanOnly:
			return MenuBarStatusSnapshot(title: "Scan-only mode — unlocking is off", opensSettings: false)
		case .normal:
			break
		}
		if isLockedOut {
			return MenuBarStatusSnapshot(title: "Locked out — password required", opensSettings: true)
		}
		if !isEnrolled {
			return MenuBarStatusSnapshot(title: "No face enrolled", opensSettings: true)
		}
		if isPaused {
			return MenuBarStatusSnapshot(
				title: "Paused until \(clock.string(from: pausedUntil ?? Date()))",
				opensSettings: false
			)
		}
		if !cameraAuthorized {
			return MenuBarStatusSnapshot(title: "Camera access needed", opensSettings: true)
		}
		if !passwordReplayEnabled {
			return MenuBarStatusSnapshot(title: "Mac unlocking is off", opensSettings: true)
		}
		if unlockBackend == .none {
			return MenuBarStatusSnapshot(title: "Recognition only", opensSettings: false)
		}
		switch readiness() {
		case .ready:
			return MenuBarStatusSnapshot(title: "Gaze is ready", opensSettings: false)
		case .needsSetup, .unavailable:
			return MenuBarStatusSnapshot(title: "Unlock needs attention — open Settings", opensSettings: true)
		}
	}
}

struct MenuBarContent: View {

	let store: FaceEnrollmentStore
	let lockout: LockoutManager

	@Environment(\.openWindow) private var openWindow
	@State private var preferences = Preferences.shared

	private var statusSnapshot: MenuBarStatusSnapshot {
		MenuBarStatusModel.evaluate(
			executionPolicy: AppServices.executionPolicy,
			isLockedOut: lockout.isLockedOut,
			isEnrolled: store.isEnrolled,
			isPaused: preferences.isPaused,
			pausedUntil: preferences.pausedUntil,
			cameraAuthorized: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
			passwordReplayEnabled: PasswordReplaySafety.isEnabled,
			unlockBackend: preferences.unlockBackend,
			readiness: {
				let backend: UnlockBackend = switch preferences.unlockBackend {
				case .none: NoUnlockBackend()
				case .keystroke: KeystrokeUnlockBackend()
				}
				return backend.readiness()
			}
		)
	}

	var body: some View {
		let status = statusSnapshot
		// Problem states open Settings; informational states stay text. The row
		// never toggles, enrolls, or unlocks — it only presents Settings.
		if status.opensSettings {
			Button {
				AppActivation.bringToFront(userInitiated: true)
				openWindow(id: "settings")
			} label: {
				Text(status.title)
			}
		} else {
			Text(status.title)
		}

		Divider()

		// Quick actions, above the windows that open. Locking is the thing you came here
		// to do; the rest is configuration.
		if store.isEnrolled {
			if preferences.isPaused {
				Button("Resume Gaze") { preferences.resume() }
			} else {
				Menu("Pause Gaze") {
					ForEach(Preferences.PauseSpan.allCases) { span in
						Button(span.title) { preferences.pause(for: span.seconds) }
					}
				}
			}
			Button("Lock Screen Now") { ScreenLock.now() }
				.keyboardShortcut("l")

			Divider()
		}

		// Shown whether or not a face is enrolled — there can be more than one now,
		// and the menu was the only way in for anyone who never opens Settings.
		if store.canAddFace {
			Button(store.isEnrolled ? "Add a Face…" : "Set Up Gaze…") {
				if store.isEnrolled { SetupRequest.begin() } else { SetupRequest.beginOnboarding() }
				AppActivation.bringToFront()
				openWindow(id: "enrollment")
			}
		}
		if store.isEnrolled {
			Button("Test Recognition…") {
				AppActivation.bringToFront()
				openWindow(id: "test")
			}
		}
		Button("Settings…") {
			AppActivation.bringToFront(userInitiated: true)
			openWindow(id: "settings")
		}

		Divider()

		Button("Quit Gaze") { NSApp.terminate(nil) }
			.keyboardShortcut("q")
	}
}
