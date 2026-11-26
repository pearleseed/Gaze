import AppKit
import GazeCore
import GazeLockScreen
import GazeRecognition
import GazeSecurity

/// The long-lived objects, owned outside the view tree.
///
/// They used to be `@State` on the App with startup hung off a `.task` on the menu bar
/// content — which only runs when the menu is *opened*. That meant the lock watcher, the
/// thing responsible for noticing your screen lock, never started unless you happened to
/// click the menu bar first.
@MainActor
final class AppServices {

	static let shared = AppServices()
	static let executionPolicy = UnlockExecutionPolicy.current
	static var isUIReview: Bool { executionPolicy != .normal }
	static var safetyNotice: String {
		executionPolicy == .scanOnly
			? "Scanning enabled on lock and wake · No password entry or automatic locking"
			: "UI review · Automatic locking and unlocking are off for this run"
	}

	let store: FaceEnrollmentStore = {
		let store = FaceEnrollmentStore()
		#if PRODUCT_CAPTURE
		// Screenshots show a stand-in face, never the owner's photo or name.
		if ProductCaptureDemo.isOn { store.loadProductCaptureDemoFace() }
		#endif
		return store
	}()
	let lockout = LockoutManager()
	/// App Lock's persisted list. The state machine below holds the only
	/// in-memory unlock state; Settings and the URL handler keep their own
	/// store instances, which agree through UserDefaults.
	let appLockStore = AppLockStore()

	/// Stub until the global fill shortcut is wired up; always false for now.
	var isAutofillShortcutRegistered = false

	private var lockWatcher: LockWatcher?
	private var presenceWatcher: PresenceWatcher?
	private var lockScreenShoot: LockScreenShoot?
	private var appLockPreview: AppLockShield?
	private var adminPrompts: AdminPromptApproval?
	private var sudoApprovals: SudoApproval?
	/// One face check for admin prompts, sudo and Shortcuts, so two can never overlap.
	private var faceApprovals: FaceApprovalCheck?
	private var appLockMachine: AppLockStateMachine?
	private var appLockWatcher: AppLockWatcher?
	private var appLockShield: AppLockShield?
	private var appLockRecognizer: AppLockRecognizer?

	private init() {}

	/// Puts a stand-in lock screen on the display, for screenshots.
	///
	/// Launch with `--shoot-lockscreen`. Separate from the developer preview, which cycles
	/// the panel's phases over the desktop and then hides it: that is for watching the
	/// animation, this is for framing one picture, and it holds until Escape.
	/// `--ui-review --app-lock-preview=<bundle id>` shows the App Lock shield over that
	/// running app with no camera, for looking at the design. `--app-lock-preview-success`
	/// plays the unlock after two seconds.
	func runAppLockPreviewIfRequested() {
		guard Self.isUIReview,
			let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--app-lock-preview=") })
		else { return }
		let bundleID = String(argument.dropFirst("--app-lock-preview=".count))
		let shield = AppLockShield(machine: AppLockStateMachine(store: AppLockStore()))
		appLockPreview = shield
		shield.show(for: bundleID)
		if CommandLine.arguments.contains("--app-lock-preview-success") {
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(2))
				shield.unlockSucceeded()
			}
		}
	}

	func runLockScreenShootIfRequested() {
		guard !Self.isUIReview else { return }
		guard CommandLine.arguments.contains("--shoot-lockscreen") else { return }
		let shoot = LockScreenShoot()
		lockScreenShoot = shoot
		shoot.run()
	}

	/// Starts or stops walk-away locking to match the launch policy and the setting.
	///
	/// Deliberately independent of the unlock backend: automatic locking needs
	/// neither password storage nor replay, so backend `none` with replay
	/// disabled still locks when the setting is on. Only the normal launch
	/// policy permits it — scan-only, UI review and any other
	/// prohibited policy stop and clear the watcher instead.
	///
	/// Idempotent: calling it when the watcher already matches the desired
	/// state neither starts a second watcher nor disturbs the running one. It
	/// touches only the presence watcher, so flipping the walk-away toggle
	/// never restarts an unlock attempt.
	func syncPresenceWatcher() {
		let shouldRun =
			Self.executionPolicy.permitsAutomaticLocking && Preferences.shared.walkAwayLock
		if shouldRun {
			guard presenceWatcher == nil else { return }
			let presence = PresenceWatcher(store: store)
			presence.start()
			presenceWatcher = presence
		} else {
			presenceWatcher?.stop()
			presenceWatcher = nil
		}
	}

	/// Starts or stops App Lock to match the launch policy and the setting.
	///
	/// The watcher, shield and recognizer share one state machine, so an
	/// unlock lasts across shield shows until the "Lock again" option says
	/// otherwise. Only the normal launch policy runs it: review and
	/// scan-only modes never cover other apps with a shield.
	///
	/// Idempotent like `syncPresenceWatcher`: a running stack is left alone,
	/// and stopping drops the in-memory unlocks with it — turning App Lock
	/// off removes every shield, so nothing may stay unlocked behind it.
	func syncAppLock() {
		let shouldRun = Self.executionPolicy == .normal && appLockStore.isEnabled
		if shouldRun {
			guard appLockWatcher == nil else { return }
			let machine = AppLockStateMachine(store: appLockStore)
			let watcher = AppLockWatcher(store: appLockStore, machine: machine)
			let shield = AppLockShield(machine: machine)
			watcher.attach(shield: shield)
			let recognizer = AppLockRecognizer(store: store, machine: machine)
			recognizer.attach(to: shield)
			watcher.start()
			appLockMachine = machine
			appLockWatcher = watcher
			appLockShield = shield
			appLockRecognizer = recognizer
		} else {
			appLockWatcher?.stop()
			appLockWatcher = nil
			appLockShield = nil
			appLockRecognizer = nil
			appLockMachine = nil
		}
	}

	/// Starts whichever trigger the selected backend needs, stopping the other.
	///
	/// Safe to call repeatedly, and it must be — changing the backend in Settings used to
	/// do nothing until the app was relaunched, which left the user on a setting that
	/// looked active while nothing was watching for the lock.
	func startUnlockTrigger() {
		// Walk-away locking first, before any early return below: prohibited
		// policies must stop a watcher left over from a mode switch, and an
		// enabled setting must start one even with backend none / replay off.
		syncPresenceWatcher()
		// Polls only while approveAdminPrompts is enabled and unpaused.
		let check = faceApprovals ?? FaceApprovalCheck(store: store, lockout: lockout)
		faceApprovals = check
		FaceApprovalCenter.check = check
		if let adminPrompts {
			adminPrompts.syncTimerState()
		} else {
			let service = AdminPromptApproval(store: store, lockout: lockout, check: check)
			service.start()
			adminPrompts = service
		}
		// Always listening, so the Settings switch works without a restart. Only
		// /usr/bin/sudo running as root can connect, and it only does once installed.
		if sudoApprovals == nil {
			let service = SudoApproval(check: check)
			service.start()
			sudoApprovals = service
		}
		// Tear down whatever was running before switching.
		lockWatcher?.stop()
		lockWatcher = nil
		if Self.executionPolicy == .scanOnly {
			_ = LockScreenSpace.shared
			let watcher = LockWatcher(store: store, lockout: lockout)
			lockWatcher = watcher
			watcher.start()
			return
		}
		guard !Self.isUIReview else { return }

		// The lock screen space, built now rather than when the screen first locks.
		//
		// `LockScreenSpace.shared` is a lazy static, and the only thing that touched it was
		// `adopt(window)` inside the capsule's `show()`. So on the first lock after launch
		// the space was created, levelled and shown *after* the window had already been
		// ordered in — all in one runloop turn, racing the window server. Measured at 407ms
		// after "Screen locked", which is the wrong side of the moment it is needed.
		//
		// Touching it at startup costs one space that sits empty until something is put in
		// it, and removes the race entirely.
		_ = LockScreenSpace.shared

		switch Preferences.shared.unlockBackend {
		case .keystroke:
			guard PasswordReplaySafety.isEnabled else { return }
			// Nothing calls us here — we have to notice the lock ourselves.
			guard lockWatcher == nil else { return }
			let watcher = LockWatcher(store: store, lockout: lockout)
			watcher.start()
			lockWatcher = watcher

		case .none:
			break
		}
	}
}
