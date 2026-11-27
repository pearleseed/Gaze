import AppKit
import GazeCore
import SwiftUI
import os

/// Owns the lock screen capsule window.
///
/// The window is created when the screen locks and destroyed when it unlocks, rather than
/// kept around hidden. That matches how the space adoption works — a window has to exist
/// and be on screen before it can be moved into the lock screen space, since SkyLight
/// addresses it by window number.
@MainActor
package final class NotchCapsuleController {

	private static let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "NotchCapsule")
	private static let horizontalInset: CGFloat = 20

	/// Asked of the window server rather than remembered, for the diagnostic line below.
	private static func screenIsLocked() -> Bool {
		guard
			let session = CGSessionCopyCurrentDictionary() as? [String: Any],
			let locked = session["CGSSessionScreenIsLocked"] as? Bool
		else { return false }
		return locked
	}

	private var window: NSWindow?
	private var host: NSHostingView<AnyView>?
	private var expansionTask: Task<Void, Never>?
	private var dismissalTask: Task<Void, Never>?
	private var screenObserver: NSObjectProtocol?
	private var contentSize: CGSize = .zero
	private var builtChallengeRoom: CGFloat = 0
	private var builtHasNotch: Bool = false
	private var builtCutoutWidth: CGFloat = 180
	/// Height of the region hidden behind the physical cutout, so the glyph can be
	/// centred in the visible part rather than in the whole window.
	private var notchInset: CGFloat = 0
	/// Last VoiceOver announcement, so the same challenge prompt is not read twice.
	private var lastAnnouncedText: String?

	/// One model for the panel's whole lifetime. Mutating it animates; replacing the
	/// hosting view's root would reset the view's state and animate nothing.
	private let model = NotchCapsuleModel()

	/// False for the panel shown on an unlocked desktop (admin prompts): there is no
	/// lock-screen space to move it into, and it should sit with ordinary windows.
	private let usesLockScreenSpace: Bool

	package init(usesLockScreenSpace: Bool = true) {
		self.usesLockScreenSpace = usesLockScreenSpace
		screenObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.repositionForScreenChange() }
		}
	}

	isolated deinit {
		if let screenObserver {
			NotificationCenter.default.removeObserver(screenObserver)
		}
	}

	private static func targetScreen() -> NSScreen? {
		NSScreen.main ?? NSScreen.screens.first
	}

	/// Updates the active window frame and SwiftUI hosting view if screen geometry or
	/// notch metrics changed (e.g. external monitor reconnecting right after wake).
	private func syncGeometry(on screen: NSScreen, for window: NSWindow) {
		let next = geometry(on: screen)
		let hasNotch = NotchMetrics.hasNotch(on: screen)
		let cutoutWidth = NotchMetrics.width(on: screen) ?? 180
		let needsRebuild = next.contentSize != contentSize || next.notchInset != notchInset
			|| hasNotch != builtHasNotch || cutoutWidth != builtCutoutWidth
		guard window.frame != next.windowFrame || next.challengeRoom != builtChallengeRoom || needsRebuild else { return }
		window.setFrame(next.windowFrame, display: true)
		contentSize = next.contentSize
		notchInset = next.notchInset
		builtChallengeRoom = next.challengeRoom
		builtHasNotch = hasNotch
		builtCutoutWidth = cutoutWidth
		let windowSize = next.windowFrame.size
		if needsRebuild {
			let newHost = NSHostingView(
				rootView: AnyView(
					NotchCapsule(
						model: model, width: next.contentSize.width, height: next.contentSize.height,
						notchInset: next.notchInset,
						cutoutWidth: cutoutWidth,
						hasNotch: hasNotch)
						.frame(width: windowSize.width, height: windowSize.height, alignment: .top)))
			newHost.frame = NSRect(origin: .zero, size: windowSize)
			window.contentView = newHost
			self.host = newHost
		} else {
			host?.frame = NSRect(origin: .zero, size: windowSize)
		}
	}

	/// Repositions and re-adopts an active capsule when displays reconfigure right after
	/// waking from Sleep (common when an external monitor reconnects).
	private func repositionForScreenChange() {
		guard let window, let screen = Self.targetScreen() else { return }
		syncGeometry(on: screen, for: window)
		syncBackdrop(for: window)
		window.orderFrontRegardless()
		if usesLockScreenSpace { LockScreenSpace.shared.adopt(window) }
	}

	/// Last build outcome, so the missing-space state is readable from Settings diagnostics rather than the log alone.
	package private(set) static var lastBuildOutcome: (message: String, at: Date)?

	/// Non-activating floating panel, so it never takes focus or enters the
	/// lock screen's input path. Follows the approval-panel prototype:
	/// borderless + nonactivating, floating, key only if needed (which, with
	/// `canBecomeKey == false` below, is never).
	private final class UnfocusableWindow: NSPanel {
		override var canBecomeKey: Bool { false }
		override var canBecomeMain: Bool { false }
	}

	// MARK: - Presentation

	package func show(phase: NotchCapsuleModel.Phase = .scanning) {
		dismissalTask?.cancel()
		model.phase = phase
		announce(phase: phase)

		if let screen = Self.targetScreen() {
			model.lightBehind = WallpaperBrightness.isLight(on: screen)
		}
		model.style = Preferences.shared.notchStyle
		model.shape = Preferences.shared.panelShape
		model.glyphPlacement = Preferences.shared.glyphPlacement
		model.usesNativeAnimation = Preferences.shared.nativeUnlockAnimation
		model.animationColour = Preferences.shared.unlockAnimationColour
		model.transparency = Preferences.shared.notchTransparency
		model.showsCaptions = Preferences.shared.showNotchCaptions

		let needsMount = window == nil
		if needsMount {
			model.isExpanded = false
			build()
		}

		guard let window else { return }
		if !needsMount, let screen = Self.targetScreen() {
			syncGeometry(on: screen, for: window)
		}
		syncBackdrop(for: window)
		window.alphaValue = 1
		window.orderFrontRegardless()
		Self.logger.notice(
			"show: window \(window.windowNumber) level \(window.level.rawValue) visible \(window.isVisible) locked \(Self.screenIsLocked())"
		)
		// After ordering in, never before: the window number does not exist until then.
		if usesLockScreenSpace { LockScreenSpace.shared.adopt(window) }
		syncLookTarget(for: phase)

		// The window itself does not fade — the panel grows out of the notch instead.
		// Fading the window would make the part behind the cutout briefly visible as a
		// ghost over the menu bar.
		// Expanded on a short delay, not on the next runloop turn.
		//
		// `DispatchQueue.main.async` fired before the hosting view had mounted, so the
		// change landed with nothing observing it and the panel stayed collapsed. The view
		// needs to exist and be on screen first; a frame or two is enough.
		if needsMount {
			expansionTask = Task { [weak self, weak window] in
				do {
					try await Task.sleep(for: .milliseconds(60))
				} catch { return }
				guard let self, let window, self.window === window else { return }
				self.model.isExpanded = true
				self.expansionTask = nil
			}
		} else if expansionTask == nil {
			model.isExpanded = true
		}
	}

	package func update(phase: NotchCapsuleModel.Phase) {
		guard window != nil else { return }
		let previous = model.phase
		model.phase = phase
		model.showsCaptions = Preferences.shared.showNotchCaptions
		// Re-read here as well as on show: the mark is what the animation setting
		// changes, and a setting that only applied to the next lock screen would be
		// one you had to lock twice to see.
		model.usesNativeAnimation = Preferences.shared.nativeUnlockAnimation
		model.animationColour = Preferences.shared.unlockAnimationColour
		if phase != previous {
			announce(phase: phase)
		}
		syncLookTarget(for: phase)
	}

	/// The edge light follows the look prompts and nothing else: up while an
	/// outward look is asked for, down for every other phase. Blink shares the
	/// look symbol but has no sideways hint, so the hint check keeps it out.
	private func syncLookTarget(for phase: NotchCapsuleModel.Phase) {
		if case .challenge(_, let symbol, let hintX, _, _, let isReturningToRest) = phase,
			symbol == "eye.fill", !isReturningToRest, hintX != 0 {
			LookTargetOverlay.shared.show(side: hintX < 0 ? .leading : .trailing)
		} else {
			LookTargetOverlay.shared.hide()
		}
	}

	/// Reads the new phase for VoiceOver, if it has anything worth saying.
	private func announce(phase: NotchCapsuleModel.Phase) {
		let text: String?
		switch phase {
		case .locked:
			text = nil
		case .scanning:
			text = "Looking for your face"
		case .notRecognised:
			text = "Face not recognised"
		case .spoofRejected:
			text = "That looked like a photo or a screen"
		case .unavailable(let message):
			text = message
		case .challenge(_, _, _, _, _, let isReturningToRest) where isReturningToRest:
			text = "Now look back at the screen"
		case .challenge(let prompt, _, _, _, _, _):
			text = prompt.isEmpty ? nil : prompt
		case .pending:
			text = "Waiting for macOS"
		case .success, .unlocked:
			text = "Unlocked"
		}
		guard let text else { return }
		// The prompt is the announcement for challenges, so the same words twice in
		// a row mean nothing new happened — other phases always read on change.
		if case .challenge = phase, text == lastAnnouncedText { return }
		lastAnnouncedText = text
		announceForVoiceOver(text)
	}

	package var canPresentGuidance: Bool {
		window?.isVisible == true && model.isExpanded && LockScreenSpace.shared.isAvailable
	}

	package func hide(after delay: TimeInterval = 0) {
		LookTargetOverlay.shared.hide()
		dismissalTask?.cancel()
		guard let window else { return }
		dismissalTask = Task { [weak self, weak window] in
			do {
				try await Task.sleep(for: .seconds(max(0, delay)))
			} catch { return }
			guard let self, let window, self.window === window else { return }

			self.expansionTask?.cancel()
			self.expansionTask = nil
			self.model.isExpanded = false

			let teardownDelay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
				? 0 : NotchAnimation.teardownDelay
			do {
				try await Task.sleep(for: .seconds(teardownDelay))
			} catch { return }
			guard self.window === window else { return }
			LockScreenSpace.shared.release(window)
			window.orderOut(nil)
			self.window = nil
			self.host = nil
			self.dismissalTask = nil
		}
	}

	/// Which wallpaper and window frame the current backdrop was cut for.
	private var backdropKey: String?

	/// Cuts the wallpaper behind the window for hand-drawn Liquid Glass, once per wallpaper,
	/// screen and window frame rather than per show or per frame. Decoded off the main
	/// thread: a 6K HEIC takes long enough to hold up the panel appearing.
	private func syncBackdrop(for window: NSWindow) {
		guard model.style == .liquidGlass, let screen = Self.targetScreen() else {
			model.backdrop = nil
			backdropKey = nil
			return
		}
		let frame = window.frame
		let url = NSWorkspace.shared.desktopImageURL(for: screen)
		let key = "\(url?.path ?? "")|\(NSStringFromRect(frame))|\(NSStringFromRect(screen.frame))"
		guard key != backdropKey else { return }
		backdropKey = key
		model.backdrop = nil
		let screenFrame = screen.frame
		Task.detached(priority: .userInitiated) { [weak self] in
			guard let url, let image = GlassBackdrop.loadImage(url) else { return }
			let rect = CGRect(
				x: frame.minX - screenFrame.minX, y: screenFrame.maxY - frame.maxY,
				width: frame.width, height: frame.height)
			let backdrop = GlassBackdrop.make(from: image, canvas: screenFrame.size, rect: rect)
			await self?.apply(backdrop, key: key)
		}
	}

	private func apply(_ backdrop: GlassBackdrop?, key: String) {
		guard backdropKey == key else { return }
		model.backdrop = backdrop
	}

	// MARK: - Construction

	private func geometry(on screen: NSScreen) -> (
		windowFrame: NSRect, contentSize: CGSize, notchInset: CGFloat, challengeRoom: CGFloat
	) {
		// Match the cutout exactly and hang directly off its bottom edge, so the panel
		// reads as the notch extending rather than a pill floating beneath it.
		// Falls back to a sensible pill on a screen with no notch.
		let notchHeight = NotchMetrics.height(on: screen)

		// Wider than the physical cutout on purpose.
		//
		// Matching the cutout exactly seemed right, but notch apps
		// draw a wider bar over that area, and a panel at the true cutout width
		// steps in narrower underneath it. The mismatch is what reads as wrong. This
		// matches the island those apps present rather than the hardware behind it.
		let notchWidth = (NotchMetrics.width(on: screen) ?? 180) * 1.56
			+ Preferences.shared.notchWidthAdjust

		// The window spans the notch as well as the area below it, so the black runs
		// continuously from the physical cutout into the panel.
		//
		// Sitting it directly *below* the notch left a seam along the top edge: the
		// cutout is true black, the wallpaper behind the menu bar usually is not, and the
		// join between them read as a border. Overlapping removes the join entirely — the
		// part behind the cutout is simply never seen.
		// Also measured: the panel hangs ~66pt below the menu bar, not the 38 I guessed.
		// The short drop was what made it read as a stub rather than a panel.
		// The island is a separate object below the housing, so the window has to carry the
		// gap and the island's own height on top of what an attached drop needs — plus room
		// underneath for its shadow.
		//
		// With the window ending exactly where the island ends, the shadow was clipped flat
		// against the bottom edge and drew a straight line across the wallpaper. That line is
		// precisely how you can tell a floating object is really a window. `islandSide` is
		// capped on width, so the extra height stays empty margin rather than making the
		// island taller.
		let hasNotch = NotchMetrics.hasNotch(on: screen)
		let isIsland = Preferences.shared.panelShape == .island
		let isDynamicIsland = Preferences.shared.panelShape == .dynamicIsland
		let isEarFlank =
			Preferences.shared.panelShape == .attached
			&& Preferences.shared.glyphPlacement == .ear && hasNotch
		let cutout = NotchMetrics.width(on: screen) ?? 180
		// Always reserved, captions or not. Tying this to the captions toggle made the
		// panel a third shorter for anyone who turned captions off, and the owner's
		// call is that the panel keeps its size — the toggle hides words, it does not
		// shrink the thing. Do not make this conditional again.
		//
		// The island, the dynamic island and the ear flank carry their captions inline,
		// so none reserves room below.
		let challengeRoom: CGFloat = (isIsland || isDynamicIsland || isEarFlank) ? 0 : ConnectedMetrics.challengeRoom
		// The dynamic island's expanded state is up to 340 x 44 below a 6pt gap, plus
		// shadow room underneath — mirrors DynamicIslandMetrics in NotchCapsule,
		// which this file cannot see (it is private to the view).
		let dropHeight =
			(isIsland ? IslandMetrics.dropHeight(cutoutWidth: cutout)
				: isDynamicIsland ? (6 + 44 + IslandMetrics.shadowRoom)
				: isEarFlank ? 8 : ConnectedMetrics.baseDropHeight)
			+ challengeRoom
			+ Preferences.shared.notchHeightAdjust
		// The ear flank widens its face side to fit a caption (EarFlankMetrics in
		// NotchCapsule: 54pt flank, 6pt gap, up to 170pt of words, 4pt padding) and
		// stays centred on the cutout, so the window holds that on both sides. The
		// dynamic island morphs to a fixed 340pt when open.
		let contentWidth =
			isDynamicIsland ? max(notchWidth, 340)
			: isEarFlank ? max(notchWidth, cutout + 2 * (54 + 6 + 170 + 4)) : notchWidth
		let panelFrame = NotchMetrics.panelFrame(
			size: CGSize(width: contentWidth, height: notchHeight + dropHeight),
			screenFrame: screen.frame,
			scale: screen.backingScaleFactor)
		let size = panelFrame.size
		let frame = panelFrame.insetBy(dx: -Self.horizontalInset, dy: 0)
		return (frame, size, notchHeight, challengeRoom)
	}

	private func build() {
		guard let screen = Self.targetScreen() else { return }

		let next = geometry(on: screen)
		let notchHeight = next.notchInset
		let size = next.contentSize
		let frame = next.windowFrame
		let windowSize = frame.size
		let cutoutWidth = NotchMetrics.width(on: screen) ?? 180
		let hasNotch = NotchMetrics.hasNotch(on: screen)
		self.contentSize = size
		self.notchInset = notchHeight
		self.builtChallengeRoom = next.challengeRoom
		self.builtHasNotch = hasNotch
		self.builtCutoutWidth = cutoutWidth

		let window = UnfocusableWindow(
			contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		window.isFloatingPanel = true
		window.becomesKeyOnlyIfNeeded = true
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = false
		window.ignoresMouseEvents = true
		// Above the fullscreen staging window (LockScreenShoot at .screenSaver)
		// and above other notch apps, not below them.
		//
		// This was `.mainMenu + 2` — level 26 — while other notch apps draw their bar at 104. On
		// the lock screen that put their bar over ours, which was survivable for the attached
		// panel and the island because both hang *below* the band and the part underneath
		// still showed. In ear mode nothing hangs below: the padlock and the mark both live
		// inside the menu bar band, so the whole indicator disappeared under their bar and
		// selecting "on the ear" looked like it did nothing at all.
		//
		// This window only exists while the screen is locked, and for those few seconds its
		// status is the thing worth seeing.
		window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 4)
		window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		window.hidesOnDeactivate = false

		let host = NSHostingView(
			rootView: AnyView(
				NotchCapsule(
					model: model, width: size.width, height: size.height,
					notchInset: notchHeight,
					cutoutWidth: cutoutWidth,
					hasNotch: hasNotch)
					.frame(width: windowSize.width, height: windowSize.height, alignment: .top)))
		host.frame = NSRect(origin: .zero, size: windowSize)
		window.contentView = host

		self.window = window
		self.host = host

		if !LockScreenSpace.shared.isAvailable {
			Self.lastBuildOutcome = ("No lock screen space; capsule will only show when unlocked.", Date())
			Self.logger.notice("No lock screen space; capsule will only show when unlocked.")
		} else {
			Self.lastBuildOutcome = nil
		}
	}

	// No render(): the model drives the view, so there is nothing to rebuild.
}

/// Posts a VoiceOver announcement, and does nothing when VoiceOver is off.
@MainActor
fileprivate func announceForVoiceOver(_ text: String) {
	guard !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
	NSAccessibility.post(
		element: NSApp as Any,
		notification: .announcementRequested,
		userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}
