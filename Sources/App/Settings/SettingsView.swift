import AppKit
import FinderSync
import SwiftUI

struct SettingsView: View {

	/// The width of the settings column, matching System Settings' own detail measure.
	/// Wider than this and a row's label and its control stop reading as one row.
	private static let contentWidth: CGFloat = 620

	let store: FaceEnrollmentStore
	let lockout: LockoutManager

	/// `--settings-pane=general|face|credits|about` opens straight onto one pane.
	///
	/// Same reason as `--setup-step`: working on a pane, or photographing one, otherwise
	/// means clicking to it after every rebuild.
	@State private var pane: SettingsPane = {
		guard
			let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--settings-pane=") }),
			let name = argument.split(separator: "=").last,
			let pane = SettingsPane(rawValue: String(name))
		else { return .face }
		return pane
	}()
	@State private var settings = Preferences.shared
	@State private var updates = RepoRevealHelper.shared
	@State private var releases = ReleaseUpdateChecker.shared
	@State private var navigator = SettingsNavigator.shared
	/// Whether a password is stored, re-read whenever this window comes forward.
	///
	/// `@State` initialises once, and until "Change" existed that was harmless: the only
	/// things that could store or revoke a password were the two buttons in this row, and
	/// both set this themselves. "Change" hands the job to the setup window, so the password
	/// can now change while Settings is sitting behind it — and the row would still be
	/// showing whatever was true when the window opened, offering to store a password that
	/// is already stored.
	@State private var hasStoredPassword = PasswordVault.hasPassword
	@State private var unlockForm = SettingsUnlockForm()
	@State private var accessibilityGranted = SetupPermissionStatus.current.isReady
	@State private var cameraGranted = Self.cameraAuthorized
	@State private var inputMonitoringGranted = SpaceKeyMonitor.isAllowed
	@State private var sudoInstalled = SudoApproval.isInstalled
	@State private var sudoError: SudoSetupFailure?
	@State private var loginItem = SettingsLoginItemState()
	/// App Lock state. `AppLockStore` is a plain class, not `@Observable`, so the
	/// pane keeps local copies and writes every change straight through to it.
	private let appLock = AppLockStore()
	@State private var appLockEnabled = false
	@State private var lockedApps: [String] = []
	@State private var relockPolicy: AppLockRelockPolicy = .afterQuit
	@State private var finderExtensionEnabled = false
	/// The settings search field. Blank means no search: the panes show as before.
	@State private var searchQuery = ""
	@State private var pauseExpiryRevision = 0
	/// The section a search result asked to reveal.
	///
	/// Set together with the destination pane and the cleared query; a `.task(id:)`
	/// on the detail scroll view scrolls to it after layout, then clears it.
	/// Navigation only — it never reads the vault or flips a setting.
	@State private var pendingSearchSection: SettingsSearchItem?
	/// The section a search navigation just revealed, highlighted briefly.
	///
	/// Owned separately from `pendingSearchSection` so the scroll task clearing
	/// on arrival never cuts the highlight short. Set together with the pane so
	/// a search-driven pane change keeps it; a manual pane switch, a new search
	/// or disappearance clears it instead. Never read for anything but display.
	@State private var highlightedSearchSection: SettingsSearchItem?
	/// Restarts the highlight expiry on every selection, including a repeat of
	/// the same section.
	@State private var highlightToken: UUID?

	@Environment(\.openWindow) private var openWindow
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		let _ = pauseExpiryRevision
		Group {
			// A search replaces the panes while it is nonempty, rather than filtering
			// rows in the panes: the panes are per-subject groups, and a filtered
			// subset of rows would orphan controls from the footers that explain them.
			if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				detail
			} else {
				searchResults
			}
		}
		.searchable(text: $searchQuery, placement: .toolbar, prompt: "Find a setting")
		// AppKit hands first focus to the first text field, which was the enrolled
		// face's name: opening Settings selected it, one keystroke from renaming.
		.onAppear {
			// After the window has become key and AppKit has picked its first responder.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
				for window in NSApp.windows {
					if let field = window.firstResponder as? NSTextView, field.isFieldEditor {
						window.makeFirstResponder(nil)
					}
				}
			}
		}
		.onChange(of: pane) { _, next in
			searchQuery = ""
			// A manual pane switch drops the highlight; a search-driven one
			// lands on the highlighted section's own pane and keeps it.
			if highlightedSearchSection?.pane != next.rawValue {
				highlightedSearchSection = nil
				highlightToken = nil
			}
		}
		.onChange(of: navigator.pending) { _, _ in consumeNavigatorRequest() }
		.onChange(of: searchQuery) { _, query in
			// Typing a new search supersedes the previous destination.
			// (Selections set the query back to empty, so they keep it.)
			if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				highlightedSearchSection = nil
				highlightToken = nil
			}
		}
		.onSubmit(of: .search) {
			if let first = SettingsSearchItem.results(for: searchQuery).first {
				selectSearchResult(first)
			}
		}
		// The pane switcher lives in the window's toolbar, which is where macOS puts
		// one. `.principal` centres it between the traffic lights and the trailing
		// edge — the same slot Finder's view switcher and Xcode's segmented controls
		// use — and AppKit owns the glass, the height and the scroll-edge behaviour.
		.toolbar {
			ToolbarItem(placement: .principal) {
				GazeSettingsPicker(selection: $pane)
					.fixedSize()
			}
			ToolbarItem(placement: .navigation) {
				if isUpdateBadgeVisible {
					Group {
						if releases.installer.state.isBusy {
							ProgressView()
								.progressViewStyle(.circular)
								.controlSize(.small)
						} else {
							Button {
								pane = .general
								revealSettingsSection("updatesSection")
							} label: {
								Label("Update available", systemImage: "square.and.arrow.down")
									.labelStyle(.iconOnly)
							}
							// A plain toolbar button: macOS sizes its glass like the pane
							// icons beside it. Custom styles here stretched to the row height.
							.foregroundStyle(.blue)
							.help("Gaze \(availableDisplayVersion) is ready to install")
							.accessibilityLabel("Update available")
						}
					}
					.transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
					.animation(reduceMotion ? nil : Theme.Motion.quick, value: isUpdateBadgeVisible)
				}
			}
		}
		// A floor, not a fixed size.
		//
		// The window was pinned at exactly 700×540 and non-resizable, which meant a user who
		// found the text small had no recourse, and a long string — a localised footer, a
		// camera driver's error message — had nowhere to go but the clip. System Settings
		// resizes; so does this now.
		//
		// `maxWidth: .infinity`, and it has to be — a `maxWidth: 920` here was a real bug.
		//
		// This view *is* the window's content, and `WindowGlass` is its background. Capping
		// the view's width did not cap the window's: dragging past 920 left the view at 920
		// inside a wider window, and the strips either side of it had no view in them at
		// all. `VibrantBackground` sets `window.isOpaque = false` so the material can sample
		// the desktop, so those strips were not merely unpainted, they were see-through —
		// the window's left and right edges became holes onto the wallpaper.
		//
		// The reasonable thing the cap was reaching for — that a 620pt column of settings
		// gains nothing from a 1400pt window — is a limit on the *window*, not on its
		// content. Until it is one, filling is correct: whatever size the window is, the
		// glass reaches its edges.
		.frame(
			minWidth: 660, idealWidth: 720, maxWidth: .infinity,
			minHeight: 480, idealHeight: 600, maxHeight: .infinity)
		// One sheet of glass, dense at the top and thinning as it falls.
		//
		// No divider between panes and no separate scrim on each: a hairline with two
		// different fills either side is what cut the window into a "web app with a
		// sidebar". On one unbroken sheet the chrome is just the edge of the glass — the way
		// the Siri panel and Spotlight treat theirs.
		.background {
			// No `WallpaperBackdrop` here any more.
			//
			// It drew its own copy of the desktop picture inside the window, scaled to the
			// window rather than to the screen — so the wallpaper indoors never lined up
			// with the wallpaper outdoors. Move the window and the picture inside it stayed
			// put; the highlight sweeping across your desktop stopped dead at the window's
			// edge and a different, unrelated gradient carried on inside. That mismatch is
			// what read as fake, and no amount of tuning the scrims above it could fix it,
			// because the thing being tuned was a painting of a wallpaper rather than the
			// wallpaper.
			//
			// A window is made of glass by sampling what is actually behind it, which is
			// `.behindWindow` blending and nothing else. It costs the wallpaper being
			// visible when the window sits over other windows — over a dark app the glass
			// goes dark — but that is what glass does, and it is what every system window
			// on macOS does.
			//
			// `keepsTitle` because the window has a title bar again: `WindowGlass` reaches
			// into the host `NSWindow` and hides it, which was correct while the switcher
			// was drawn in the content view, and would now take the toolbar down with it.
			WindowGlass(keepsTitle: true, extraTranslucent: settings.appTheme == .glass)
		}
		// Nil for "follow system", which is what following the system means — forcing a
		// scheme is the thing this setting exists to make optional.
		.preferredColorScheme(settings.appTheme.colorScheme)
		.environment(\.settingsGroupFill, settings.appTheme == .glass ? Theme.settingsGlassGroupFill : Theme.settingsGroupFill)
		.onAppear {
			AppActivation.bringToFront()
			refreshExternalState()
			consumePendingPane()
			consumeNavigatorRequest()
		}
		// Both of these can be changed outside this window — the password by the setup flow
		// that "Change" opens, Accessibility in System Settings — and neither sends a
		// notification of its own. Coming back to the app is the moment to ask again.
		.onReceive(
			NotificationCenter.default.publisher(
				for: NSApplication.didBecomeActiveNotification)
		) { _ in
			refreshExternalState()
		}
		.task(id: settings.pausedUntil) {
			guard let until = settings.pausedUntil, until > Date() else { return }
			do { try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow))) }
			catch { return }
			// Pause expiry changes with time, without changing the stored preference.
			pauseExpiryRevision &+= 1
		}
		.task(id: highlightToken) {
			// The highlight's own lifetime: a newer selection replaces the token
			// and cancels this, so only the latest destination stays highlighted.
			guard highlightToken != nil else { return }
			try? await Task.sleep(for: .seconds(1.8))
			guard !Task.isCancelled else { return }
			highlightedSearchSection = nil
		}
		.onDisappear {
			highlightedSearchSection = nil
			highlightToken = nil
			AppActivation.returnToBackgroundIfIdle()
		}
	}

	// MARK: - Detail

	private var detail: some View {
		let highlightedSection = highlightedSearchSection?.section
		return ScrollViewReader { proxy in
			ScrollView {
				VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
					switch pane {
					case .face:
						SettingsUnlockPane(
							store: store,
							lockout: lockout,
							settings: settings,
							isPaused: settings.isPaused,
							cameraGranted: cameraGranted,
							accessibilityGranted: accessibilityGranted,
							hasStoredPassword: $hasStoredPassword,
							form: $unlockForm,
							highlightedSection: highlightedSection,
							openSetup: openSetup,
							revealSettingsSection: revealSettingsSection)
					// Movements and the security checks share a tab: both decide how hard Gaze
					// is to fool. `movements` and `attempts` stay as `--settings-pane` aliases.
					case .security, .movements:
						SettingsSecurityPane(
							settings: settings,
							cameraGranted: cameraGranted,
							accessibilityGranted: accessibilityGranted,
							inputMonitoringGranted: $inputMonitoringGranted,
							sudoInstalled: $sudoInstalled,
							sudoError: $sudoError,
							highlightedSection: highlightedSection,
							reviewAccessibility: { openSetup(at: .permission) })
					case .attempts:
						UnlockAttemptsSection().settingsDestination("unlockAttemptsSection", highlightedSection: highlightedSection)
					// Its own pane, like Screen Time or Passwords in System Settings: a switch,
					// the list it governs, then its options. As a group at the bottom of Unlock
					// it was hard to find, and its list sat above its own heading.
					case .apps:
						SettingsAppLockPane(
							appLock: appLock,
							appLockEnabled: $appLockEnabled,
							lockedApps: $lockedApps,
							relockPolicy: $relockPolicy,
							finderExtensionEnabled: finderExtensionEnabled,
							highlightedSection: highlightedSection)
					case .general:
						// Updates first, so a waiting update is the first thing General shows.
						SettingsUpdatesSection(updates: updates, releases: releases)
							.settingsDestination("updatesSection", highlightedSection: highlightedSection)
						SettingsBehaviourSection(settings: settings, loginItem: $loginItem)
							.settingsDestination("behaviourSection", highlightedSection: highlightedSection)
						appearanceSection.settingsDestination("appearanceSection", highlightedSection: highlightedSection)
						onboardingSection.settingsDestination("onboardingSection", highlightedSection: highlightedSection)
					case .notch:
						NotchSettingsSection(settings: settings).settingsDestination("NotchSettingsSection", highlightedSection: highlightedSection)
					case .credits:
						SettingsCreditsPane().settingsDestination("creditsSection", highlightedSection: highlightedSection)
					case .about:
						SettingsAboutPane(store: store, updates: updates).settingsDestination("aboutSection", highlightedSection: highlightedSection)
						DisclosureGroup {
							SettingsCreditsPane()
						} label: {
							Theme.disclosureLabel("Credits & Acknowledgements")
						}
						.settingsDisclosureRow()
					}

					Spacer(minLength: 0)
				}
				// A measure, then centred — not stretched to whatever width the window is.
				//
				// The groups were pinned left at full width, so dragging the window wider pulled
				// every row's control away from its label until a switch could sit 600pt from
				// the word it belonged to, with the right half of the window empty. Settings
				// panes have a column width and keep it; the window growing gives you more rows
				// on screen, not wider ones.
				.frame(maxWidth: Self.contentWidth, alignment: .leading)
				.frame(maxWidth: .infinity)
				.padding(.horizontal, 24)
				// The toolbar owns the traffic-light clearance now, so this is just the gap
				// under the glass rather than a hand-measured dodge around the buttons.
				.padding(.top, 20)
				.padding(.bottom, 24)
			}
			.scrollIndicators(.never)
			// Scrolls to a search result's section after the pane switch lays out,
			// so the anchor exists when it scrolls. Keyed by the destination rather
			// than delayed by a fixed interval; unanimated, and cleared on arrival.
			#if PRODUCT_CAPTURE
			// Capture tool only: `--settings-section=<anchor>` scrolls a section into view
			// for a screenshot. Never compiled into the shipping app.
			.task {
				guard ProductCaptureDemo.isOn,
					let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--settings-section=") })
				else { return }
				try? await Task.sleep(for: .milliseconds(600))
				proxy.scrollTo(String(arg.dropFirst("--settings-section=".count)), anchor: .top)
			}
			#endif
			.task(id: pendingSearchSection?.id) {
				guard let target = pendingSearchSection else { return }
				proxy.scrollTo(target.section, anchor: .top)
				pendingSearchSection = nil
			}
		}
	}

	/// The search results, replacing the panes while the query is nonempty.
	///
	/// One restrained row per match — title and subtitle, nothing more. Each row
	/// only navigates: it switches to the result's pane, clears the query, and
	/// asks the detail scroll view to reveal the matching section. Selecting a
	/// result never reads the vault, toggles a setting, or opens a permission
	/// prompt or enrolment flow.
	private var searchResults: some View {
		let matches = SettingsSearchItem.results(for: searchQuery)
		return ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				if matches.isEmpty {
					Text("No settings match \"\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\".")
						.font(Typography.detail)
						.foregroundStyle(Theme.secondaryLabel)
						.padding(.horizontal, Theme.rowInset)
						.padding(.vertical, 14)
					Button("Clear search") {
						searchQuery = ""
						highlightedSearchSection = nil
						highlightToken = nil
					}
						.gazeButton()
						.padding(.horizontal, Theme.rowInset)
				} else {
					ForEach(matches) { item in
						Button { selectSearchResult(item) } label: {
							VStack(alignment: .leading, spacing: 3) {
								Text(item.title)
									.font(Typography.control)
									.foregroundStyle(Theme.label)
								Text(item.subtitle)
									.font(Typography.detail)
									.foregroundStyle(Theme.secondaryLabel)
							}
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.horizontal, Theme.rowInset)
							.padding(.vertical, 10)
						}
						.buttonStyle(.plain)
						if item.id != matches.last?.id {
							RowDivider(inset: 0)
						}
					}
				}

				Spacer(minLength: 0)
			}
			.frame(maxWidth: Self.contentWidth, alignment: .leading)
			.frame(maxWidth: .infinity)
			.padding(.horizontal, 24)
			.padding(.top, 20)
			.padding(.bottom, 24)
		}
		.scrollIndicators(.never)
	}

	private func selectSearchResult(_ item: SettingsSearchItem) {
		if let next = SettingsPane(rawValue: item.pane) { pane = next }
		searchQuery = ""
		pendingSearchSection = item
		highlightedSearchSection = item
		highlightToken = UUID()
	}

	private func revealSettingsSection(_ section: String) {
		guard let item = SettingsSearchItem.all.first(where: { $0.section == section }) else { return }
		selectSearchResult(item)
	}

	/// Applies an external open-Settings request (notification click): selects the pane
	/// and reveals the section, then clears it so repeating the same destination still
	/// observes a change.
	private func consumeNavigatorRequest() {
		guard let next = navigator.pending else { return }
		navigator.pending = nil
		if let destination = SettingsPane(rawValue: next.pane) { pane = destination }
		revealSettingsSection(next.section)
	}

	private var isUpdateBadgeVisible: Bool {
		if case .available = releases.state { return true }
		return false
	}

	private var availableDisplayVersion: String {
		guard case .available(let release) = releases.state else { return "" }
		return ReleaseUpdateChecker.displayVersion(for: release.tag)
	}

	private var onboardingSection: some View {
		SettingsSection(title: "Getting Started") {
			SettingsNavigationRow(title: "Welcome to Gaze", detail: "Reopen the setup walkthrough.") {
				SetupRequest.beginOnboarding()
				AppActivation.bringToFront(userInitiated: true)
				openWindow(id: "enrollment")
			}
			RowDivider()
			SettingsNavigationRow(title: "Movement guide", detail: "Preview the prompts with the camera off.") {
				AppActivation.bringToFront(userInitiated: true)
				openWindow(id: "movement-guide")
			}
		}
	}

	/// Opens setup on one screen.
	///
	/// The password and permission screens are skipped during a normal run once they are
	/// satisfied, which is right the first time through and leaves them unreachable ever
	/// after. Settings is where someone goes looking for them, so Settings is what names
	/// them.
	private func openSetup(at step: SetupStep) {
		SetupRequest.begin(at: step)
		AppActivation.bringToFront()
		openWindow(id: "enrollment")
	}

	/// Re-reads the state this window shows but does not own.
	private func refreshExternalState() {
		hasStoredPassword = PasswordVault.hasPassword
		cameraGranted = Self.cameraAuthorized
		accessibilityGranted = SetupPermissionStatus.current.isReady
		inputMonitoringGranted = SpaceKeyMonitor.isAllowed
		sudoInstalled = SudoApproval.isInstalled
		if sudoError?.enabling == sudoInstalled { sudoError = nil }
		appLockEnabled = appLock.isEnabled
		lockedApps = appLock.lockedBundleIDs.sorted()
		relockPolicy = appLock.relockPolicy
		finderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
		loginItem.refresh()
	}

	/// Navigates to a pane staged by a handing-off `--settings-pane=` launch.
	///
	/// A handoff reuses this process, so argv never carries the new request — the
	/// handing-off process leaves the validated pane name under
	/// `SettingsLaunchHandoff.pendingPaneKey` instead. Only a known pane wins;
	/// anything else leaves the argv-derived initial pane alone. Consumed once.
	private func consumePendingPane() {
		guard
			let name = UserDefaults.standard.string(forKey: SettingsLaunchHandoff.pendingPaneKey),
			let staged = SettingsPane(rawValue: name)
		else { return }
		pane = staged
		UserDefaults.standard.removeObject(forKey: SettingsLaunchHandoff.pendingPaneKey)
	}

	// MARK: - Appearance

	/// The app's own look, at the foot of the pane.
	///
	/// Last on purpose: everything above it configures what Gaze *does*, and this
	/// configures what the window you are reading is made of. It is the one setting whose
	/// effect you can see the instant you change it, so it does not need to be found first.
	private var appearanceSection: some View {
		SettingsSection(
			title: "Appearance",
			info: settings.appTheme == .glass
				? "Semi Liquid Glass uses a dark, translucent surface. Onboarding follows "
					+ "this appearance too. The notch has its own style in Notch settings."
				: "Applies to Settings and onboarding. The recognition test keeps a neutral "
					+ "camera surround. The notch has its own style in Notch settings."
		) {
			VStack(alignment: .leading, spacing: 12) {
				Text("Theme").font(Typography.row).foregroundStyle(Theme.label)
				ThemePreviewPicker(selection: $settings.appTheme)
			}
			.padding(.horizontal, Theme.rowInset)
			.padding(.vertical, 14)
		}
	}
}
