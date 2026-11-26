import Darwin
import SwiftUI

@main
struct GazeApp: App {

	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	private var store: FaceEnrollmentStore { AppServices.shared.store }
	private var lockout: LockoutManager { AppServices.shared.lockout }
	private let presentsSettingsAtLaunch: Bool
	@StateObject private var menuBarVisibility = MenuBarVisibility.shared

	init() {
		// Same-bundle foreground handoff: a `--settings` (or bare) launch while this
		// bundle is already running presents the running app and exits here, before
		// StartupTiming/AppServices/OnboardingHistory or any service starts. Flagged
		// launches (notably `--agent`) never take this exit, so KeepAlive relaunches
		// cannot loop on it.
		// Renders and exits when asked; no services start.
		LockPanelPreview.runIfRequested()
		if SettingsLaunchHandoff.redirectIfNeeded() { Darwin.exit(0) }
		let totalStart = StartupTiming.start()
		// Read synchronously: SwiftUI evaluates `defaultLaunchBehavior` once, at launch, so
		// a value that arrives later from a Task never reaches the window.
		let enrolled = StartupTiming.measure(label: "services") { AppServices.shared.store.isEnrolled }
		if enrolled { OnboardingHistory.markPresented() }
		presentsSettingsAtLaunch = !AppActivation.isBackgroundLaunch
			&& !OnboardingHistory.presentsSetup(isEnrolled: enrolled, arguments: CommandLine.arguments)
		StartupTiming.finish(label: "gazeapp-init-total", start: totalStart)
	}

	var body: some Scene {
		// Only while the setting says so: flipping "Show in menu bar" removes or
		// re-adds the icon without relaunching, via MenuBarVisibility below.
		MenuBarExtra(isInserted: $menuBarVisibility.isVisible) {
			MenuBarContent(store: store, lockout: lockout)
		} label: {
			GazeStatusItemLabel()
		}
		// A real menu, not a window.
		//
		// Left to `.automatic`, SwiftUI backed this with a panel — and that panel stayed
		// alive at alpha 0, layer 101, parked under the menu bar item in the top-right of the
		// screen. An invisible window above normal windows eats every click inside its
		// rectangle, so clicks near the top-right corner intermittently did nothing *in other
		// applications*. The content here is a list of buttons; it wants an NSMenu.
		.menuBarExtraStyle(.menu)

		Window("Gaze", id: "settings") {
			SettingsView(store: store, lockout: lockout)
				.scrollIndicators(.never)
				.safeAreaInset(edge: .bottom, spacing: 0) {
					if AppServices.isUIReview {
						Label(AppServices.safetyNotice, systemImage: "lock.shield")
							.font(.caption).foregroundStyle(.secondary)
							.padding(10).frame(maxWidth: .infinity).background(.bar)
					}
				}
				// Registers the Settings opener outside the menu bar label, so
				// reopening Gaze still opens Settings while the icon is hidden.
				.background(SettingsOpenerSetup())
		}
		.defaultLaunchBehavior(presentsSettingsAtLaunch ? .presented : .suppressed)
		// `.contentMinSize`, not `.contentSize`: the view states a floor and an ideal, and
		// the user is allowed to go bigger. A settings window that cannot be resized has no
		// answer for someone who finds the text small.
		.windowResizability(.contentMinSize)
		// Opens at the size the view asks for rather than at whatever it was last dragged
		// to. Without this the frame AppKit had saved won — including a frame left behind
		// by resizing it once during development — so the window could open enormous and
		// mostly empty and stay that way for good.
		.defaultSize(width: 720, height: 600)
		// A real title bar, carrying a real `NSToolbar`.
		//
		// This was `.hiddenTitleBar`, and that one line is what forced everything above the
		// content to be hand-made. With no title bar there is nowhere for a toolbar to live,
		// so the pane switcher became a control floating in the content area, and the
		// content then needed `.padding(.top, 30)` to duck under the traffic lights that
		// were now sitting on top of it. The result read as a web page's tab strip: a bar of
		// words across the top of a window, which is the shape of the *system* menu bar.
		//
		// The window's own toolbar is the thing macOS puts a pane switcher in, and on
		// macOS 26 it is Liquid Glass without being asked — the real material, with the
		// scroll-edge effect and the traffic-light spacing handled by AppKit. None of that
		// can be reproduced by drawing a capsule in the content view, which is why the
		// previous two attempts at drawing it both ended up looking like a drawing of it.
		.windowToolbarStyle(.unified(showsTitle: false))

		Window("Test Recognition", id: "test") {
			RecognitionTestView(store: store)
		}
		.windowResizability(.contentMinSize)
		.defaultSize(width: 600, height: 700)

		// Behind a launch flag, and deliberately not in any menu. Collecting an
		// anti-spoof dataset is a job for whoever is building the model, not a
		// feature — but the crops have to come from this pipeline, so the tool has
		// to live in this app.
		Window("Capture Dataset", id: "dataset") {
			DatasetCaptureView()
				.scrollIndicators(.never)
		}
		.windowResizability(.contentSize)

		Window("Set Up Gaze", id: "enrollment") {
			EnrollmentWindow(store: store)
				.scrollIndicators(.never)
				.containerBackground(.clear, for: .window)
				.background(KeyablePlainWindow())
		}
		.windowResizability(.contentSize)
		.defaultSize(width: 760, height: 680)
		.restorationBehavior(.disabled)
		.windowStyle(.plain)
		.defaultLaunchBehavior(!AppActivation.isBackgroundLaunch && !presentsSettingsAtLaunch ? .presented : .suppressed)

		// The camera-free movement guide. Suppressed at launch: it only ever opens
		// from the guide entries in Settings and Notch settings, never on its own.
		Window("Movement guide", id: "movement-guide") {
			GazeMovementGuideWindow()
				.background(KeyablePlainWindow())
		}
		.windowResizability(.contentSize)
		.defaultSize(width: 760, height: 680)
		.restorationBehavior(.disabled)
		.windowStyle(.plain)
		.defaultLaunchBehavior(.suppressed)
	}

}

/// Thin host around `GazeMovementTour`; the window owns presentation, the tour
/// only owns its pages.
///
/// Mirrors `SetupWelcomeStep`: an invisible drag strip along the top edge (a `.plain`
/// window has no title bar to grab) and a return to accessory activation once the
/// window is gone. The child identity resets on every appearance so reopening the
/// guide starts on page one. No camera, no permissions, no enrollment — the tour
/// never starts any of them.
private struct GazeMovementGuideWindow: View {

	@Environment(\.dismissWindow) private var dismissWindow
	@State private var tourRevision = 0

	var body: some View {
		GazeMovementTour(
			onClose: { dismissWindow(id: "movement-guide") },
			movementCount: Preferences.shared.unlockMovementCount.rawValue
		)
		// The tour card is dark-only; without this a light system turned the
		// panel pale while its text stayed white.
		.preferredColorScheme(.dark)
		.containerBackground(.clear, for: .window)
		// Recreated on reopening so the tour starts on page one.
		.id(tourRevision)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.overlay(alignment: .top) {
			Color.clear
				.frame(height: 10)
				.contentShape(Rectangle())
				.gesture(WindowDragGesture())
				.allowsWindowActivationEvents(true)
				.accessibilityHidden(true)
		}
		.onAppear { tourRevision += 1 }
		.onDisappear { AppActivation.returnToBackgroundIfIdle() }
	}
}
