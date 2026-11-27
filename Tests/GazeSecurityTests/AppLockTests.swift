import Foundation
import GazeCore
import GazeSecurity
import Testing

@Suite("App Lock Store, State Machine, Watcher & Finder URL")
@MainActor
struct AppLockTests {
	private static let lockedApp = "com.example.locked"
	private static let freeApp = "com.example.free"
	private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
	private static let neverLockable = [
		"com.pearleseed.Gaze",
		"com.apple.finder",
		"com.apple.systempreferences",
		"com.apple.loginwindow",
	]

	private func makeIsolatedStore() throws -> (store: AppLockStore, cleanup: () -> Void) {
		let suiteName = "com.pearleseed.Gaze.AppLockTests.\(UUID().uuidString)"
		let groupName = suiteName + ".group"
		let defaults = try #require(UserDefaults(suiteName: suiteName))
		let group = try #require(UserDefaults(suiteName: groupName))
		defaults.removePersistentDomain(forName: suiteName)
		group.removePersistentDomain(forName: groupName)
		let store = AppLockStore(defaults: defaults, groupDefaults: group)
		return (
			store,
			{
				defaults.removePersistentDomain(forName: suiteName)
				group.removePersistentDomain(forName: groupName)
			}
		)
	}

	@Test func relockPolicyTitlesAndAfterQuitLifecycle() throws {
		#expect(AppLockRelockPolicy.afterQuit.title == "After quitting")
		#expect(AppLockRelockPolicy.afterFiveMinutesInBackground.title == "After 5 minutes in the background")
		#expect(AppLockRelockPolicy.everyTime.title == "Every time it opens")
		#expect(AppLockStateMachine.backgroundLimit == 5 * 60)

		let (store, cleanup) = try makeIsolatedStore()
		defer { cleanup() }

		#expect(store.relockPolicy == .afterQuit)
		store.relockPolicy = .afterQuit
		store.add(Self.lockedApp)
		let machine = AppLockStateMachine(store: store)
		#expect(machine.state(for: Self.lockedApp, now: Self.t0) == .locked)
		#expect(machine.needsShield(Self.lockedApp, now: Self.t0))

		machine.unlock(Self.lockedApp, now: Self.t0)
		#expect(machine.state(for: Self.lockedApp, now: Self.t0) == .unlocked)
		#expect(!machine.needsShield(Self.lockedApp, now: Self.t0))

		machine.appDidResign(Self.lockedApp, now: Self.t0)
		machine.appDidActivate(Self.lockedApp, now: Self.t0)
		#expect(machine.state(for: Self.lockedApp, now: Self.t0) == .unlocked)

		machine.appDidQuit(Self.lockedApp)
		#expect(machine.state(for: Self.lockedApp, now: Self.t0) == .locked)
		#expect(machine.needsShield(Self.lockedApp, now: Self.t0))

		// Late launch notice keeps the unlock it came after; genuinely new launch locks again.
		let launched = Self.t0.addingTimeInterval(10)
		machine.unlock(Self.lockedApp, now: launched.addingTimeInterval(1))
		machine.appDidLaunch(Self.lockedApp, launchedAt: launched)
		#expect(machine.state(for: Self.lockedApp, now: launched.addingTimeInterval(2)) == .unlocked)

		machine.appDidLaunch(Self.lockedApp, launchedAt: launched.addingTimeInterval(5))
		#expect(machine.state(for: Self.lockedApp, now: launched.addingTimeInterval(6)) == .locked)

		machine.unlock(Self.lockedApp, now: launched.addingTimeInterval(20))
		machine.appDidQuit(Self.lockedApp)
		#expect(machine.needsShield(Self.lockedApp, now: launched.addingTimeInterval(20.5)))
	}

	@Test func backgroundTimeoutEveryTimeSleepAndScreenLock() throws {
		// After 5 minutes in the background.
		let (store5, cleanup5) = try makeIsolatedStore()
		defer { cleanup5() }
		store5.relockPolicy = .afterFiveMinutesInBackground
		store5.add(Self.lockedApp)
		let machine5 = AppLockStateMachine(store: store5)
		machine5.unlock(Self.lockedApp, now: Self.t0)
		machine5.appDidResign(Self.lockedApp, now: Self.t0)
		#expect(machine5.state(for: Self.lockedApp, now: Self.t0.addingTimeInterval(4 * 60)) == .unlocked)
		#expect(machine5.state(for: Self.lockedApp, now: Self.t0.addingTimeInterval(5 * 60)) == .locked)
		#expect(machine5.needsShield(Self.lockedApp, now: Self.t0.addingTimeInterval(5 * 60)))

		// Coming back to the front clears the background clock.
		machine5.unlock(Self.lockedApp, now: Self.t0)
		machine5.appDidResign(Self.lockedApp, now: Self.t0)
		machine5.appDidActivate(Self.lockedApp, now: Self.t0.addingTimeInterval(60))
		#expect(machine5.state(for: Self.lockedApp, now: Self.t0.addingTimeInterval(6 * 60)) == .unlocked)

		// A later resign must not restart the clock.
		let (storeResign, cleanupResign) = try makeIsolatedStore()
		defer { cleanupResign() }
		storeResign.relockPolicy = .afterFiveMinutesInBackground
		storeResign.add(Self.lockedApp)
		let machineResign = AppLockStateMachine(store: storeResign)
		machineResign.unlock(Self.lockedApp, now: Self.t0)
		machineResign.appDidResign(Self.lockedApp, now: Self.t0)
		machineResign.appDidResign(Self.lockedApp, now: Self.t0.addingTimeInterval(2 * 60))
		#expect(machineResign.state(for: Self.lockedApp, now: Self.t0.addingTimeInterval(5 * 60)) == .locked)

		// Every time it opens.
		let (storeEvery, cleanupEvery) = try makeIsolatedStore()
		defer { cleanupEvery() }
		storeEvery.relockPolicy = .everyTime
		storeEvery.add(Self.lockedApp)
		let machineEvery = AppLockStateMachine(store: storeEvery)
		machineEvery.unlock(Self.lockedApp, now: Self.t0)
		#expect(machineEvery.state(for: Self.lockedApp, now: Self.t0) == .unlocked)
		machineEvery.appDidResign(Self.lockedApp, now: Self.t0)
		#expect(machineEvery.state(for: Self.lockedApp, now: Self.t0) == .locked)
		machineEvery.unlock(Self.lockedApp, now: Self.t0)
		machineEvery.appDidQuit(Self.lockedApp)
		#expect(machineEvery.state(for: Self.lockedApp, now: Self.t0) == .locked)

		// Sleep and screen lock relock under every policy.
		for policy in AppLockRelockPolicy.allCases {
			let (policyStore, policyCleanup) = try makeIsolatedStore()
			defer { policyCleanup() }
			policyStore.relockPolicy = policy
			policyStore.add(Self.lockedApp)
			let policyMachine = AppLockStateMachine(store: policyStore)
			policyMachine.unlock(Self.lockedApp, now: Self.t0)
			policyMachine.systemDidSleep()
			#expect(policyMachine.state(for: Self.lockedApp, now: Self.t0) == .locked)
			policyMachine.unlock(Self.lockedApp, now: Self.t0)
			policyMachine.screenDidLock()
			#expect(policyMachine.state(for: Self.lockedApp, now: Self.t0) == .locked)
		}
	}

	@Test func neverLockableListWatcherAndFaceMisses() throws {
		#expect(AppLockStore.appGroupID == "group.com.pearleseed.Gaze")
		#expect(AppIdentity.finderExtensionIdentifier == "com.pearleseed.Gaze.Finder")
		#expect(AppLockStore.neverLockable.count == 4)

		let (store, cleanup) = try makeIsolatedStore()
		defer { cleanup() }

		for bundleID in Self.neverLockable {
			#expect(AppLockStore.isNeverLockable(bundleID))
			#expect(!store.add(bundleID))
			#expect(!store.isLocked(bundleID))
		}
		store.add(Self.lockedApp)
		store.lockedBundleIDs = Set(Self.neverLockable).union([Self.lockedApp])
		#expect(store.lockedBundleIDs == [Self.lockedApp])

		let machine = AppLockStateMachine(store: store)
		for bundleID in Self.neverLockable {
			machine.unlock(bundleID, now: Self.t0)
			#expect(!machine.needsShield(bundleID, now: Self.t0))
		}

		// Watcher shield-needed callbacks.
		let (watcherStore, watcherCleanup) = try makeIsolatedStore()
		defer { watcherCleanup() }
		watcherStore.add(Self.lockedApp)
		let watcherMachine = AppLockStateMachine(store: watcherStore)
		let watcher = AppLockWatcher(store: watcherStore, machine: watcherMachine)
		#expect(watcher.shouldShield(bundleID: Self.lockedApp, now: Self.t0))
		#expect(!watcher.shouldShield(bundleID: Self.freeApp, now: Self.t0))

		var shielded: [String] = []
		watcher.onShieldNeeded = { shielded.append($0) }
		#expect(watcher.appDidActivate(bundleID: Self.lockedApp, now: Self.t0))
		#expect(shielded == [Self.lockedApp])

		watcherMachine.unlock(Self.lockedApp, now: Self.t0)
		#expect(!watcher.shouldShield(bundleID: Self.lockedApp, now: Self.t0))
		#expect(!watcher.appDidActivate(bundleID: Self.lockedApp, now: Self.t0))
		#expect(shielded == [Self.lockedApp])

		watcherMachine.appDidQuit(Self.lockedApp)
		#expect(watcher.appDidActivate(bundleID: Self.lockedApp, now: Self.t0))
		#expect(shielded == [Self.lockedApp, Self.lockedApp])

		for bundleID in Self.neverLockable {
			#expect(!watcher.shouldShield(bundleID: bundleID, now: Self.t0))
			#expect(!watcher.appDidActivate(bundleID: bundleID, now: Self.t0))
		}
		#expect(shielded == [Self.lockedApp, Self.lockedApp])

		// Face misses disable after 3 until unlock.
		let (missStore, missCleanup) = try makeIsolatedStore()
		defer { missCleanup() }
		missStore.add(Self.lockedApp)
		let missMachine = AppLockStateMachine(store: missStore)
		#expect(missMachine.faceMissCount(for: Self.lockedApp) == 0)
		#expect(!missMachine.isFaceDisabled(Self.lockedApp))
		missMachine.recordFaceMiss(Self.lockedApp)
		missMachine.recordFaceMiss(Self.lockedApp)
		#expect(missMachine.faceMissCount(for: Self.lockedApp) == 2)
		#expect(!missMachine.isFaceDisabled(Self.lockedApp))
		missMachine.recordFaceMiss(Self.lockedApp)
		#expect(missMachine.faceMissCount(for: Self.lockedApp) == AppLockStateMachine.maxFaceMisses)
		#expect(missMachine.isFaceDisabled(Self.lockedApp))
		missMachine.unlock(Self.lockedApp, now: Self.t0)
		#expect(missMachine.faceMissCount(for: Self.lockedApp) == 0)
		#expect(!missMachine.isFaceDisabled(Self.lockedApp))

		missMachine.recordFaceMiss(Self.lockedApp)
		missMachine.unlock(Self.lockedApp, now: Self.t0)
		#expect(missMachine.faceMissCount(for: Self.lockedApp) == 0)
	}

	@Test func finderMenuTitlesToggleURLAndAuthorization() async throws {
		#expect(FinderLockMenu.title(selectedCount: 1, appBundleID: Self.lockedApp, isLocked: true) == "Unlock with Gaze")
		#expect(FinderLockMenu.title(selectedCount: 1, appBundleID: Self.lockedApp, isLocked: false) == "Lock with Gaze")
		for bundleID in Self.neverLockable {
			#expect(FinderLockMenu.title(selectedCount: 1, appBundleID: bundleID, isLocked: false) == nil)
			#expect(FinderLockMenu.title(selectedCount: 1, appBundleID: bundleID, isLocked: true) == nil)
		}
		#expect(FinderLockMenu.title(selectedCount: 0, appBundleID: Self.lockedApp, isLocked: false) == nil)
		#expect(FinderLockMenu.title(selectedCount: 2, appBundleID: Self.lockedApp, isLocked: false) == nil)
		#expect(FinderLockMenu.title(selectedCount: 1, appBundleID: nil, isLocked: false) == nil)
		#expect(FinderLockMenu.title(selectedCount: 1, appBundleID: "", isLocked: false) == nil)

		let (store, cleanup) = try makeIsolatedStore()
		defer { cleanup() }

		let toggle = try #require(FinderLockMenu.toggleURL(for: Self.lockedApp))
		#expect(FinderLockMenu.bundleID(fromToggleURL: toggle) == Self.lockedApp)
		#expect(AppLockURLAction.bundleID(from: toggle) == Self.lockedApp)

		let badURLs = [
			"gaze://app-lock/toggle",
			"gaze://app-lock/toggle?bundle=",
			"https://example.com/",
			"gaze://other/toggle?bundle=\(Self.lockedApp)",
			"gaze://app-lock/other?bundle=\(Self.lockedApp)",
		].compactMap { URL(string: $0) }
		#expect(badURLs.count == 5)
		for bad in badURLs {
			#expect(FinderLockMenu.bundleID(fromToggleURL: bad) == nil)
			#expect(AppLockURLAction.bundleID(from: bad) == nil)
			let changed = await AppLockURLAction.perform(url: bad, store: store, authorize: { _ in true })
			#expect(!changed)
		}

		let lockURL = try #require(FinderLockMenu.toggleURL(for: Self.lockedApp))
		#expect(await AppLockURLAction.perform(url: lockURL, store: store, authorize: { _ in true }))
		#expect(store.isLocked(Self.lockedApp))
		#expect(!(await AppLockURLAction.perform(url: lockURL, store: store, authorize: { _ in false })))
		#expect(store.isLocked(Self.lockedApp))
		#expect(await AppLockURLAction.perform(url: lockURL, store: store, authorize: { _ in true }))
		#expect(!store.isLocked(Self.lockedApp))
		#expect(!(await AppLockURLAction.perform(url: lockURL, store: store, authorize: { _ in false })))
		#expect(!store.isLocked(Self.lockedApp))

		for bundleID in Self.neverLockable {
			let neverURL = try #require(FinderLockMenu.toggleURL(for: bundleID))
			#expect(!(await AppLockURLAction.perform(url: neverURL, store: store, authorize: { _ in true })))
			#expect(!store.isLocked(bundleID))
		}
	}
}
