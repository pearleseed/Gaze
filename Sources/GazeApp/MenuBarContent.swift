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

struct MenuBarContent: View {

	/// Just the time, in whatever form this Mac writes times. Built once — a
	/// `DateFormatter` per menu redraw is a surprising amount of work for six characters.
	private static let clock: DateFormatter = {
		let formatter = DateFormatter()
		formatter.timeStyle = .short
		formatter.dateStyle = .none
		return formatter
	}()

	let store: FaceEnrollmentStore
	let lockout: LockoutManager

	@Environment(\.openWindow) private var openWindow
	@State private var preferences = Preferences.shared

	private var menuStatus: String {
		switch AppServices.executionPolicy {
		case .uiReview: return "UI review — unlocking is off"
		case .scanOnly: return "Scan-only mode — unlocking is off"
		case .normal: break
		}
		if lockout.isLockedOut { return "Locked out — password required" }
		if !store.isEnrolled { return "No face enrolled" }
		if preferences.isPaused {
			return "Paused until \(Self.clock.string(from: preferences.pausedUntil ?? Date()))"
		}
		if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { return "Camera access needed" }
		if !PasswordReplaySafety.isEnabled { return "Mac unlocking is off" }
		if preferences.unlockBackend == .none { return "Recognition only" }
		let backend: UnlockBackend = switch preferences.unlockBackend {
		case .none: NoUnlockBackend()
		case .keystroke: KeystrokeUnlockBackend()
		}
		switch backend.readiness() {
		case .ready: return "Gaze is ready"
		case .needsSetup, .unavailable: return "Unlock needs attention — open Settings"
		}
	}

	/// Whether the status row opens Settings: the same conditions as
	/// `menuStatus`, minus the informational states (ready, paused,
	/// recognition-only, restricted execution modes). Matched on conditions,
	/// never on the displayed strings.
	private var menuStatusOpensSettings: Bool {
		switch AppServices.executionPolicy {
		case .uiReview, .scanOnly: return false
		case .normal: break
		}
		if lockout.isLockedOut { return true }
		if !store.isEnrolled { return true }
		if preferences.isPaused { return false }
		if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { return true }
		if !PasswordReplaySafety.isEnabled { return true }
		if preferences.unlockBackend == .none { return false }
		let backend: UnlockBackend = switch preferences.unlockBackend {
		case .none: NoUnlockBackend()
		case .keystroke: KeystrokeUnlockBackend()
		}
		switch backend.readiness() {
		case .ready: return false
		case .needsSetup, .unavailable: return true
		}
	}

	var body: some View {
		// Problem states open Settings; informational states stay text. The row
		// never toggles, enrolls, or unlocks — it only presents Settings.
		if menuStatusOpensSettings {
			Button {
				AppActivation.bringToFront(userInitiated: true)
				openWindow(id: "settings")
			} label: {
				Text(menuStatus)
			}
		} else {
			Text(menuStatus)
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
