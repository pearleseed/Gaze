import Foundation
import GazeCore
import Testing
@testable import GazeApp

@Suite("App Readiness — Wallpaper Load Gate")
struct WallpaperRequestsTests {
	private let a = URL(fileURLWithPath: "/test/wallpaper-a.png")
	private let b = URL(fileURLWithPath: "/test/wallpaper-b.png")
	private let now = Date(timeIntervalSince1970: 1_000)

	@Test func coalescesPendingAndLoadedRequests() throws {
		var gate = WallpaperLoadGate()
		let initialRequest = gate.request(for: a, now: now)
		let request = try #require(initialRequest)
		let duplicateCoalesced = gate.request(for: a, now: now) == nil
		#expect(duplicateCoalesced)
		let completed = gate.complete(request, succeeded: true, now: now)
		#expect(completed)
		let cached = gate.request(for: a, now: now) == nil
		#expect(cached)
	}

	@Test func newerSelectionRejectsLateCompletion() throws {
		var gate = WallpaperLoadGate()
		let firstRequest = gate.request(for: a, now: now)
		let first = try #require(firstRequest)
		let latestRequest = gate.request(for: b, now: now)
		let latest = try #require(latestRequest)
		let oldRejected = !gate.complete(first, succeeded: true, now: now)
		#expect(oldRejected)
		#expect(gate.pendingRequest == latest)
		let latestAccepted = gate.complete(latest, succeeded: true, now: now)
		#expect(latestAccepted)
	}

	@Test func returningToCachedWallpaperInvalidatesPendingWork() throws {
		var gate = WallpaperLoadGate()
		let firstRequest = gate.request(for: a, now: now)
		let first = try #require(firstRequest)
		let firstAccepted = gate.complete(first, succeeded: true, now: now)
		#expect(firstAccepted)
		let pendingRequest = gate.request(for: b, now: now)
		let pending = try #require(pendingRequest)
		let cacheReused = gate.request(for: a, now: now) == nil
		#expect(cacheReused)
		#expect(gate.pendingRequest == nil)
		let pendingRejected = !gate.complete(pending, succeeded: true, now: now)
		#expect(pendingRejected)
		let stillCached = gate.request(for: a, now: now) == nil
		#expect(stillCached)
	}

	@Test func failureRetriesAtTenSeconds() throws {
		var gate = WallpaperLoadGate()
		let initialRequest = gate.request(for: a, now: now)
		let request = try #require(initialRequest)
		let failureRecorded = gate.complete(request, succeeded: false, now: now)
		#expect(failureRecorded)
		let cooldownActive = gate.request(for: a, now: now.addingTimeInterval(9.99)) == nil
		#expect(cooldownActive)
		let retryRequest = gate.request(for: a, now: now.addingTimeInterval(10))
		let retry = try #require(retryRequest)
		#expect(retry != request)
		let retrySucceeded = gate.complete(retry, succeeded: true, now: now.addingTimeInterval(10))
		#expect(retrySucceeded)
		let successCached = gate.request(for: a, now: now.addingTimeInterval(20)) == nil
		#expect(successCached)
	}

	@Test func failedOldRequestCannotPoisonNewSelection() throws {
		var gate = WallpaperLoadGate()
		let oldRequest = gate.request(for: a, now: now)
		let old = try #require(oldRequest)
		let latestRequest = gate.request(for: b, now: now)
		let latest = try #require(latestRequest)
		let oldFailureRejected = !gate.complete(old, succeeded: false, now: now)
		#expect(oldFailureRejected)
		let newAccepted = gate.complete(latest, succeeded: true, now: now)
		#expect(newAccepted)
		let oldCanRetry = gate.request(for: a, now: now) != nil
		#expect(oldCanRetry)
	}

	@Test func cooldownSurvivesOtherSelections() throws {
		var gate = WallpaperLoadGate()
		let failedRequest = gate.request(for: a, now: now)
		let failed = try #require(failedRequest)
		let failureRecorded = gate.complete(failed, succeeded: false, now: now)
		#expect(failureRecorded)
		let pendingRequest = gate.request(for: b, now: now)
		let pending = try #require(pendingRequest)
		let cooldownActive = gate.request(for: a, now: now.addingTimeInterval(1)) == nil
		#expect(cooldownActive)
		let pendingRejected = !gate.complete(pending, succeeded: true, now: now)
		#expect(pendingRejected)
		let cooldownExpired = gate.request(for: a, now: now.addingTimeInterval(10)) != nil
		#expect(cooldownExpired)
	}

	@Test func resetRejectsOutstandingCompletionEvenForSameURL() throws {
		var gate = WallpaperLoadGate()
		let oldRequest = gate.request(for: a, now: now)
		let old = try #require(oldRequest)
		gate.reset()
		let freshRequest = gate.request(for: a, now: now)
		let fresh = try #require(freshRequest)
		#expect(fresh != old)
		let oldRejected = !gate.complete(old, succeeded: true, now: now)
		#expect(oldRejected)
		let freshAccepted = gate.complete(fresh, succeeded: true, now: now)
		#expect(freshAccepted)
	}

	@Test func repeatedFailuresBackOffExponentiallyAndResetOnSuccess() throws {
		var gate = WallpaperLoadGate()
		var t = now

		// 1st failure -> 10s, 2nd -> 30s, 3rd -> 90s, 4th+ -> capped at 300s.
		for expectedCooldown: TimeInterval in [10, 30, 90, 300, 300] {
			let pending = gate.request(for: a, now: t)
			let request = try #require(pending)
			let recorded = gate.complete(request, succeeded: false, now: t)
			#expect(recorded)
			let stillCooling = gate.request(for: a, now: t.addingTimeInterval(expectedCooldown - 0.1)) == nil
			#expect(stillCooling)
			t = t.addingTimeInterval(expectedCooldown)
		}

		// Recovery clears the backoff counter so a later failure starts back at 10s.
		let recoveredPending = gate.request(for: a, now: t)
		let recovered = try #require(recoveredPending)
		let recoveredOK = gate.complete(recovered, succeeded: true, now: t)
		#expect(recoveredOK)
		let otherPending = gate.request(for: b, now: t)
		let other = try #require(otherPending)
		let otherOK = gate.complete(other, succeeded: true, now: t)
		#expect(otherOK)
		let afterResetPending = gate.request(for: a, now: t)
		let afterReset = try #require(afterResetPending)
		let failedAgain = gate.complete(afterReset, succeeded: false, now: t)
		#expect(failedAgain)
		let cooledBeforeTen = gate.request(for: a, now: t.addingTimeInterval(9.9)) == nil
		#expect(cooledBeforeTen)
		let retriedAtTen = gate.request(for: a, now: t.addingTimeInterval(10)) != nil
		#expect(retriedAtTen)
	}
}
