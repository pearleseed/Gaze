import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GazeCore
import GazeDesign

struct SettingsAppLockPane: View {
	let appLock: AppLockStore
	@Binding var appLockEnabled: Bool
	@Binding var lockedApps: [String]
	@Binding var relockPolicy: AppLockRelockPolicy
	let finderExtensionEnabled: Bool
	let highlightedSection: String?

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		appLockSection.settingsDestination("appLockSection", highlightedSection: highlightedSection)
		appLockListSection.settingsDestination("appLockListSection", highlightedSection: highlightedSection)
		appLockOptionsSection.settingsDestination("appLockOptionsSection", highlightedSection: highlightedSection)
	}

	/// Apps that need your face to open, modelled on iOS 18's "Require Face ID".
	private var appLockSection: some View {
		SettingsSection(
			footer: "App Lock keeps apps private from people using your Mac. It doesn’t encrypt them. Turning it off or removing an app asks for Touch ID or your password.") {
			// The same header card the Unlock pane opens with: Gaze's icon, where things
			// stand in one line, and the one control that matters.
			HStack(spacing: 14) {
				Image(nsImage: GazeBrand.appIcon)
					.resizable()
					.interpolation(.high)
					.frame(width: 42, height: 42)
					.overlay(alignment: .bottomTrailing) {
						Image(systemName: "lock.fill")
							.font(.system(size: 10, weight: .bold))
							.foregroundStyle(.white)
							.frame(width: 20, height: 20)
							.background(Circle().fill(appLockEnabled ? Color.accentColor : Theme.grey))
							.overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
							.offset(x: 4, y: 4)
					}
					.accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 3) {
					Text(appLockEnabled ? "App Lock is on" : "App Lock is off")
						.font(Typography.heroTitle)
						.foregroundStyle(Theme.label)
						.contentTransition(.opacity)
					Text(appLockSummary)
						.font(Typography.detail)
						.foregroundStyle(Theme.secondaryLabel)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 8)
				Toggle("App Lock", isOn: Binding(get: { appLockEnabled },
					set: { newValue in
						// Turning it on only adds protection; turning it off asks first.
						guard !newValue else { setAppLockEnabled(true); return }
						Task {
							guard await BiometricGate.require(.changeAppLock) else { return }
							setAppLockEnabled(false)
						}
					}))
					.toggleStyle(.switch)
					.labelsHidden()
					.accessibilityLabel("App Lock")
			}
			.padding(.horizontal, Theme.rowInset)
			.padding(.vertical, 16)
			.animation(reduceMotion ? nil : .smooth(duration: 0.3), value: appLockEnabled)
		}
	}

	private func setAppLockEnabled(_ enabled: Bool) {
		appLock.isEnabled = enabled
		appLockEnabled = enabled
		AppServices.shared.syncAppLock()
	}

	/// Apps people usually want private, that are installed and not locked yet.
	private var suggestedApps: [String] {
		let candidates = [
			"com.apple.MobileSMS", "com.apple.Photos", "com.apple.Notes", "com.apple.mail",
			"net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop",
			"com.hnc.Discord", "com.apple.iCal", "com.apple.Passwords",
		]
		return candidates.filter { id in
			!lockedApps.contains(id) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
		}
		.prefix(5).map { $0 }
	}

	private func lockSuggestedApp(_ bundleID: String) {
		guard appLock.add(bundleID) else { return }
		withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
			lockedApps = appLock.lockedBundleIDs.sorted()
		}
	}

	private var appLockSummary: String {
		guard appLockEnabled else { return "Turn on to have apps ask for your face before they open" }
		switch lockedApps.count {
		case 0: return "Add apps that should ask for your face"
		case 1: return "\(Self.appName(for: lockedApps[0])) asks for your face before it opens"
		default: return "\(lockedApps.count) apps ask for your face before they open"
		}
	}

	/// The locked apps, as a list with its own heading and one way to add to it.
	private var appLockListSection: some View {
		SettingsSection(title: "Locked Apps") {
			if lockedApps.isEmpty {
				VStack(spacing: 10) {
					Image(systemName: "lock.app.dashed")
						.font(.system(size: 30, weight: .light))
						.foregroundStyle(Theme.secondaryLabel)
						.accessibilityHidden(true)
					Text("No locked apps")
						.font(.system(size: 15, weight: .semibold))
						.foregroundStyle(Theme.label)
					Text("Add an app, like Messages or Photos, to ask for your face before it opens.")
						.font(Typography.detail)
						.foregroundStyle(Theme.secondaryLabel)
						.multilineTextAlignment(.center)
						.frame(maxWidth: 320)
					Button("Add App…") { addLockedApp() }
						.gazeButton()
						.padding(.top, 4)
						.accessibilityLabel("Add an app to lock")
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, 22)
			} else {
				ForEach(Array(lockedApps.enumerated()), id: \.element) { index, bundleID in
					if index > 0 { RowDivider() }
					TrackpadSwipeToRemove(onRemove: { removeLockedApp(bundleID) }) {
						SettingRow(title: Self.appName(for: bundleID), portrait: Self.appIcon(for: bundleID)) {
							Button {
								removeLockedApp(bundleID)
							} label: {
								Label("Remove", systemImage: "minus.circle.fill")
									.labelStyle(.iconOnly)
									.font(.system(size: 16))
									.foregroundStyle(Theme.secondaryLabel)
									.contentShape(Circle())
							}
							.buttonStyle(.plain)
							.help("Remove \(Self.appName(for: bundleID))")
							.accessibilityLabel("Remove \(Self.appName(for: bundleID))")
						}
					}
					.contextMenu {
						Button("Remove \(Self.appName(for: bundleID))", role: .destructive) { removeLockedApp(bundleID) }
					}
				}
				RowDivider()
				Button { addLockedApp() } label: {
					Label("Add App…", systemImage: "plus")
						.font(.body)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal, Theme.rowInset)
						.padding(.vertical, 12)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.foregroundStyle(Color.accentColor)
				.accessibilityLabel("Add an app to lock")
			}
			appLockSuggestions
		}
		.disabled(!appLockEnabled)
		.opacity(appLockEnabled ? 1 : 0.5)
	}

	/// One click to lock the apps people most often want private.
	@ViewBuilder private var appLockSuggestions: some View {
		if !suggestedApps.isEmpty {
			RowDivider(inset: 0)
			VStack(alignment: .leading, spacing: 10) {
				Text("Suggested")
					.font(Typography.detail)
					.foregroundStyle(Theme.secondaryLabel)
				HStack(spacing: 8) {
					ForEach(suggestedApps, id: \.self) { bundleID in
						Button { lockSuggestedApp(bundleID) } label: {
							HStack(spacing: 6) {
								if let icon = Self.appIcon(for: bundleID) {
									Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
								}
								Text(Self.appName(for: bundleID)).font(.system(size: 12, weight: .medium))
								Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
									.foregroundStyle(Theme.secondaryLabel)
							}
							.padding(.leading, 6).padding(.trailing, 10).frame(height: 28)
							.background(Capsule().fill(Theme.surfaceRaised))
							.contentShape(Capsule())
						}
						.buttonStyle(.plain)
						.help("Lock \(Self.appName(for: bundleID))")
						.accessibilityLabel("Lock \(Self.appName(for: bundleID))")
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, Theme.rowInset)
			.padding(.vertical, 12)
		}
	}

	private var appLockOptionsSection: some View {
		SettingsSection(title: "Options") {
			SettingRow(title: "Lock again", symbol: "timer") {
				SettingsChoiceMenu(title: "Lock again",
					valueLabel: Self.relockTitle(for: relockPolicy),
					selection: Binding(get: { relockPolicy },
						set: { newValue in
							// Stricter needs nothing; looser asks first.
							let strictness: [AppLockRelockPolicy: Int] = [.afterQuit: 0, .afterFiveMinutesInBackground: 1, .everyTime: 2]
							let apply = {
								appLock.relockPolicy = newValue
								relockPolicy = newValue
							}
							guard strictness[newValue, default: 0] < strictness[relockPolicy, default: 0] else { apply(); return }
							Task {
								guard await BiometricGate.require(.changeAppLock) else { return }
								apply()
							}
						})) {
					ForEach(AppLockRelockPolicy.allCases, id: \.self) { policy in
						Text(Self.relockTitle(for: policy)).tag(policy)
					}
				}
			}
			RowDivider()
			SettingRow(
				title: "Lock from Finder",
				detail: "Right-click an app and choose Lock with Gaze",
				symbol: "cursorarrow.click.2"
			) {
				if finderExtensionEnabled {
					Text("On").foregroundStyle(Theme.secondaryLabel)
				} else {
					Button("Turn On…") { openFinderExtensionSettings() }
						.gazeButton()
						.fixedSize()
				}
			}
		}
		.disabled(!appLockEnabled)
		.opacity(appLockEnabled ? 1 : 0.5)
	}

	/// What the "Lock again" options mean, in the row's own words.
	///
	/// The store's titles describe the trigger from the app's side ("Every time
	/// it opens"); these describe it from the reader's side — when they get
	/// asked again. Raw values persist, so this changes no behaviour.
	private static func relockTitle(for policy: AppLockRelockPolicy) -> String {
		switch policy {
		case .afterQuit: return "When you quit the app"
		case .afterFiveMinutesInBackground: return "After 5 minutes away"
		case .everyTime: return "Every time you switch to it"
		}
	}

	/// System Settings opens on General > Login Items & Extensions > Finder,
	/// where Finder extensions are enabled. macOS leaves that to the user.
	private func openFinderExtensionSettings() {
		guard
			let url = URL(
				string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
		else { return }
		NSWorkspace.shared.open(url)
	}

	private func addLockedApp() {
		let panel = NSOpenPanel()
		panel.directoryURL = URL(fileURLWithPath: "/Applications")
		panel.allowedContentTypes = [.applicationBundle]
		panel.allowsMultipleSelection = true
		panel.message = "Choose apps to lock"
		panel.canChooseDirectories = false
		panel.canChooseFiles = true
		panel.begin { response in
			guard response == .OK else { return }
			var added = false
			for url in panel.urls {
				guard let bundleID = Bundle(url: url)?.bundleIdentifier,
					appLock.add(bundleID)
				else { continue }
				added = true
			}
			guard added else { return }
			withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
				lockedApps = appLock.lockedBundleIDs.sorted()
			}
		}
	}

	/// Removing an app weakens App Lock, so it asks for Touch ID or the password first.
	private func removeLockedApp(_ bundleID: String) {
		Task {
			guard await BiometricGate.require(.changeAppLock) else { return }
			appLock.remove(bundleID)
			withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
				lockedApps = appLock.lockedBundleIDs.sorted()
			}
		}
	}

	private static func appName(for bundleID: String) -> String {
		guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
		let stripped = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
		return stripped.isEmpty ? bundleID : stripped
	}

	private static func appIcon(for bundleID: String) -> NSImage? {
		guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
		return NSWorkspace.shared.icon(forFile: url.path)
	}
}

/// A row you can two-finger swipe left on the trackpad to reveal Remove, like Mail and
/// Reminders. A short swipe leaves Remove showing; a long one removes straight away.
///
/// Settings rows sit in a plain stack rather than a `List`, which is where SwiftUI's own
/// swipe actions live, so this reads the trackpad's scroll events itself: only horizontal
/// swipes that start over the row are taken; vertical scrolling passes through untouched.
private struct TrackpadSwipeToRemove<Content: View>: View {
	let onRemove: () -> Void
	@ViewBuilder let content: Content

	@State private var offset: CGFloat = 0
	@State private var hovering = false
	@State private var tracking = false
	/// The flick that follows a swipe belongs to the swipe, not to the page.
	@State private var swallowMomentum = false
	@State private var monitor: Any?
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private static var reveal: CGFloat { 88 }
	private static var removeDistance: CGFloat { 200 }

	var body: some View {
		content
			.offset(x: offset)
			.frame(maxWidth: .infinity)
			// Behind the row, so revealing it never changes the row's height. The label
			// keeps its natural width and is clipped by the red area as it opens, the way
			// Mail's is; letting it shrink wrapped "Remove" into a column of letters.
			.background(alignment: .trailing) {
				if offset < 0 {
					ZStack(alignment: .leading) {
						Theme.danger
						Text("Remove")
							.font(.system(size: 13, weight: .semibold))
							.foregroundStyle(.white)
							.lineLimit(1)
							.fixedSize()
							.padding(.leading, 22)
							.opacity(min(1, Double(-offset / 60)))
					}
					.frame(width: -offset)
					.clipped()
					.contentShape(Rectangle())
					.onTapGesture {
						settle(to: 0)
						onRemove()
					}
					.accessibilityHidden(true)
				}
			}
			.clipped()
			.onHover { inside in
				hovering = inside
				if !inside, !tracking, offset != 0 { settle(to: 0) }
			}
			.onAppear { install() }
			.onDisappear { uninstall() }
	}

	private func settle(to value: CGFloat) {
		withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { offset = value }
	}

	private func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
			// Trackpad gestures have phases; a mouse wheel doesn't, and is left alone.
			if event.phase == .began {
				tracking = hovering && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
			}
			if !event.momentumPhase.isEmpty {
				guard swallowMomentum else { return event }
				if event.momentumPhase == .ended { swallowMomentum = false }
				return nil
			}
			guard tracking else { return event }
			let wasPast = offset <= -Self.removeDistance
			offset = min(0, max(-Self.removeDistance - 40, offset + event.scrollingDeltaX))
			// A tap under the fingers as the swipe crosses into "remove", like Mail.
			if wasPast != (offset <= -Self.removeDistance) {
				NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
			}
			if event.phase == .ended || event.phase == .cancelled {
				tracking = false
				swallowMomentum = true
				if offset <= -Self.removeDistance {
					settle(to: 0)
					onRemove()
				} else {
					settle(to: offset < -Self.reveal / 2 ? -Self.reveal : 0)
				}
			}
			return nil
		}
	}

	private func uninstall() {
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
	}
}
