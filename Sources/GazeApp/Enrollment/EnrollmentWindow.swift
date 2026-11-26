import SwiftUI
import GazeCore
import GazeRecognition

/// Wraps the enrolment flow so it can dismiss its own window.
struct EnrollmentWindow: View {

	let store: FaceEnrollmentStore

	@Environment(\.dismissWindow) private var dismissWindow
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		SetupFlow(store: store) {
			dismissWindow(id: "enrollment")
		}
		.task {
			// Settings has no way in but the menu bar, which makes it the one window that
			// cannot be opened from a script — so checking a change to it meant clicking
			// through the menu by hand every rebuild. `--settings` opens it straight from
			// the command line.
			//
			// It lives here because this window is the only scene guaranteed to exist at
			// launch, so it is the only savedApp holding an `openWindow` this early.
			// Same trick as `--settings`: this window is the only scene guaranteed to
			// exist at launch, so it is the only savedApp holding an `openWindow` early
			// enough to hand off to another one.
			//
			// Launch flags apply to the presentation launch made, not to every one.
			//
			// `CommandLine.arguments` never changes, and this `task` runs each time the
			// window is presented — so reading the flags unguarded let a debug argument
			// hijack every later opening for the life of the process. Under `--settings`,
			// pressing "Add a Face" opened this window, whose task found `--settings` still
			// set, dismissed itself and re-opened Settings: the flow vanished the instant it
			// appeared. `SetupFlow.consumeLaunchStep` carries the same fix for
			// `--setup-step`, for the same reason.
			//
			// Asked as "did somebody ask for this window", not as "is this the first time it
			// has appeared". Counting presentations was the obvious version and it broke the
			// flags outright: the task runs more than once at launch, so the first run spent
			// the one permitted use and was then torn down before it could act, leaving the
			// second run with nothing to do. A deliberate open always announces itself
			// through `SetupRequest.begin()`, which is a fact about intent rather than about
			// ordering, and cannot be raced.
			let isLaunchPresentation = !SetupRequest.isDeliberateOpen

			if isLaunchPresentation, CommandLine.arguments.contains("--capture-dataset") {
				try? await Task.sleep(for: .milliseconds(200))
				AppActivation.bringToFront()
				openWindow(id: "dataset")
				dismissWindow(id: "enrollment")
				return
			}

			if isLaunchPresentation, CommandLine.arguments.contains("--settings") {
				// One runloop turn before opening. `openWindow` called while the scene graph
				// is still being set up is dropped silently — the flag looked ignored.
				//
				// Open first, dismiss second, too: dismissing this window tears down the
				// view running this very task, so anything after it never runs.
				try? await Task.sleep(for: .milliseconds(200))
				AppActivation.bringToFront()
				openWindow(id: "settings")
				dismissWindow(id: "enrollment")
				return
			}

			// `--setup` keeps this window open even when a face is already enrolled.
			// Without it, working on the setup flow means clicking the menu bar item
			// after every rebuild, because launch dismisses the window for anyone who is
			// already set up — which, once you have tested it once, is you.
			if isLaunchPresentation, CommandLine.arguments.contains("--setup") {
				AppActivation.bringToFront()
				return
			}

			AppActivation.bringToFront(userInitiated: SetupRequest.isDeliberateOpen)
		}
		.onDisappear { AppActivation.returnToBackgroundIfIdle() }
	}
}
