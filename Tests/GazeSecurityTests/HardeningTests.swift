import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import GazeRecognition
import GazeSecurity
import GazeUpdates
import Testing
import Vision

@Suite("Security Hardening — Sessions, Camera Gate, Budgets, Lockout, URLs, AntiSpoof & Autofill")
@MainActor
struct HardeningTests {
	private enum InjectedFailure: Error {
		case injected
	}

	private nonisolated static func makeSample() throws -> FaceSample {
		var pixelBuffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
		)
		#expect(status == kCVReturnSuccess)
		let buffer = try #require(pixelBuffer)
		let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
		let face = VNFaceObservation(boundingBox: box)
		let request = VNDetectFaceLandmarksRequest()
		request.inputFaceObservations = [face]
		try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
		let landmarks = try #require(request.results?.first?.landmarks)
		return FaceSample(
			landmarks: landmarks,
			boundingBox: box,
			pose: .zero,
			quality: 0.8,
			hasQualityMeasurement: true,
			pixelBuffer: buffer
		)
	}

	@Test func autofillSessionValidationAndLeaseInvalidation() {
		let identifier = UUID().uuidString
		var values: [String: Any] = [
			kCGSessionOnConsoleKey as String: true,
			kCGSessionLoginDoneKey as String: true,
			kCGSessionUserIDKey as String: UInt32(501),
			"CGSSessionUniqueSessionUUID": identifier,
		]
		let original = AutofillConsoleSession.validated(values, owner: 501)
		#expect(original != nil)
		#expect(AutofillConsoleSession.validated(values, owner: 502) == nil)
		#expect(AutofillConsoleSession.validated(nil, owner: 501) == nil)

		values["CGSSessionScreenIsLocked"] = true
		#expect(AutofillConsoleSession.validated(values, owner: 501) == nil)

		values["CGSSessionScreenIsLocked"] = "false"
		#expect(AutofillConsoleSession.validated(values, owner: 501) == nil)

		values["CGSSessionScreenIsLocked"] = false
		values[kCGSessionOnConsoleKey as String] = false
		#expect(AutofillConsoleSession.validated(values, owner: 501) == nil)

		values[kCGSessionOnConsoleKey as String] = true
		values["CGSSessionUniqueSessionUUID"] = "invalid"
		#expect(AutofillConsoleSession.validated(values, owner: 501) == nil)

		let workspace = NotificationCenter()
		let distributed = NotificationCenter()
		for name in [
			NSWorkspace.willSleepNotification,
			NSWorkspace.screensDidSleepNotification,
			NSWorkspace.sessionDidResignActiveNotification,
		] {
			let lease = AutofillSessionLease(current: { original }, workspace: workspace, distributed: distributed)
			var invalidations = 0
			lease.onInvalidation = { invalidations += 1 }
			#expect(lease.isValid)
			workspace.post(name: name, object: nil)
			workspace.post(name: name, object: nil)
			#expect(!lease.isValid && invalidations == 1)
		}

		for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
			let lease = AutofillSessionLease(current: { original }, workspace: workspace, distributed: distributed)
			distributed.post(name: Notification.Name(name), object: nil)
			#expect(!lease.isValid)
		}

		var current = original
		let lease = AutofillSessionLease(current: { current }, workspace: workspace, distributed: distributed)
		current = AutofillConsoleSession(userID: 501, identifier: UUID().uuidString)
		#expect(!lease.isValid)
		current = original
		#expect(!lease.isValid)
	}

	@Test func cameraSessionGateScopesAndLeaseReplacement() throws {
		let original = AutofillConsoleSession(userID: 501, identifier: UUID().uuidString)
		var current: AutofillConsoleSession? = original
		let workspace = NotificationCenter()
		let distributed = NotificationCenter()
		var sessions: [AutofillSessionLease] = []
		let gate = CameraSessionGate(scope: .foreground) {
			let session = AutofillSessionLease(current: { current }, workspace: workspace, distributed: distributed)
			sessions.append(session)
			return session
		}
		var stops = 0
		#expect(!gate.isValid)

		for name in [
			NSWorkspace.willSleepNotification,
			NSWorkspace.screensDidSleepNotification,
			NSWorkspace.sessionDidResignActiveNotification,
		] {
			#expect(gate.begin { stops += 1 })
			let previousStops = stops
			workspace.post(name: name, object: nil)
			workspace.post(name: name, object: nil)
			#expect(!gate.isValid && stops == previousStops + 1)
		}

		for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
			#expect(gate.begin { stops += 1 })
			let previousStops = stops
			distributed.post(name: Notification.Name(name), object: nil)
			#expect(!gate.isValid && stops == previousStops + 1)
		}

		current = nil
		#expect(!gate.begin { stops += 1 })
		current = original
		#expect(!gate.isValid)
		#expect(gate.begin { stops += 1 })

		current = AutofillConsoleSession(userID: 501, identifier: UUID().uuidString)
		let beforeReplacement = stops
		#expect(!gate.isValid && stops == beforeReplacement + 1)

		current = original
		#expect(gate.begin { stops += 1 })
		let stale = try #require(sessions.last)
		#expect(gate.begin { stops += 1 })
		let beforeStale = stops
		stale.invalidate()
		#expect(gate.isValid && stops == beforeStale)

		gate.end()
		gate.end()
		#expect(!gate.isValid && stops == beforeStale)

		let lockCamera = CameraSessionGate(scope: .lockScreen) {
			preconditionFailure("Lock-screen scanning must not acquire a foreground-only lease")
		}
		#expect(lockCamera.begin { stops += 1 })
		distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
		#expect(lockCamera.isValid && stops == beforeStale)
	}

	@Test func attemptBudgetLimitsStorageLatchesAndOverflowGuards() {
		var stored: AutofillAttemptBudget.State?
		var failRead = false
		var failWrite = false
		var ignoreWrite = false
		func makeBudget() -> AutofillAttemptBudget {
			AutofillAttemptBudget(
				load: {
					if failRead { throw InjectedFailure.injected }
					return stored
				},
				save: {
					if failWrite { throw InjectedFailure.injected }
					if !ignoreWrite { stored = $0 }
				}
			)
		}

		let budget = makeBudget()
		for attempt in 1...AutofillAttemptBudget.limit {
			#expect(budget.reserve() && stored?.attempts == attempt)
		}
		#expect(!budget.reserve())
		#expect(!makeBudget().reserve())
		#expect(budget.resetAfterOwnerApproval() && budget.reserve())

		failRead = true
		#expect(!budget.reserve())
		failRead = false
		#expect(!budget.reserve())
		#expect(budget.resetAfterOwnerApproval())

		failWrite = true
		#expect(!budget.reserve())
		#expect(!budget.resetAfterOwnerApproval())
		failWrite = false

		_ = budget.resetAfterOwnerApproval()
		ignoreWrite = true
		#expect(!budget.reserve())
		ignoreWrite = false

		stored = .init(attempts: -1)
		#expect(!makeBudget().reserve())
		stored = .init(attempts: Int.max)
		#expect(!makeBudget().reserve())
	}

	@Test func lockoutManagerFailClosedPersistenceAndCounterGuards() {
		var stored: LockoutManager.State?
		let manager = LockoutManager(load: { stored }, save: { stored = $0 })
		#expect(manager.attemptsRemaining == 6)
		for _ in 0..<6 { manager.recordFailure() }
		#expect(!manager.mayAttempt() && manager.attemptsRemaining == 0)
		manager.recordFailure()
		#expect(stored?.consecutiveFailures == 6)

		let reloaded = LockoutManager(load: { stored }, save: { stored = $0 })
		#expect(reloaded.isLockedOut)
		manager.clearAfterPasswordAuth()
		#expect(manager.mayAttempt() && stored?.consecutiveFailures == 0)

		for invalid in [-1, Int.min, 7, Int.max] {
			let corrupt = LockoutManager(load: { .init(consecutiveFailures: invalid) }, save: { _ in })
			#expect(corrupt.isLockedOut && corrupt.attemptsRemaining == 0)
			corrupt.recordFailure()
			#expect(corrupt.isLockedOut)
		}

		let unreadable = LockoutManager(load: { throw InjectedFailure.injected }, save: { _ in })
		#expect(unreadable.isLockedOut)

		let writeFailure = LockoutManager(load: { nil }, save: { _ in throw InjectedFailure.injected })
		writeFailure.recordFailure()
		#expect(writeFailure.isLockedOut)

		let dropped = LockoutManager(load: { nil }, save: { _ in })
		dropped.recordFailure()
		#expect(dropped.isLockedOut)
		dropped.clearAfterPasswordAuth()
		#expect(dropped.isLockedOut)
	}

	@Test func frameLeaseFrameGateAndMatchHold() {
		let start = ContinuousClock.now
		var lease = CameraFrameLease()
		let first = lease.begin()
		#expect(lease.accepts(first, capturedAt: start, now: start))
		#expect(!lease.accepts(first, capturedAt: start, now: start.advanced(by: .seconds(1))))
		#expect(!lease.accepts(first, capturedAt: start.advanced(by: .seconds(1)), now: start))
		lease.stop()
		#expect(!lease.accepts(first, capturedAt: start, now: start))
		let second = lease.begin()
		#expect(first != second && !lease.accepts(first, capturedAt: start, now: start))

		var frames = RecognitionFrameGate(now: start)
		#expect(frames.observe(id: 1, capturedAt: start, now: start) == .fresh(continuous: false))
		#expect(frames.observe(id: 1, capturedAt: start, now: start.advanced(by: .milliseconds(100))) == .waiting)
		let next = start.advanced(by: .milliseconds(120))
		#expect(frames.observe(id: 2, capturedAt: next, now: next) == .fresh(continuous: true))
		let gap = start.advanced(by: .milliseconds(500))
		#expect(frames.observe(id: 3, capturedAt: gap, now: gap) == .fresh(continuous: false))
		#expect(frames.observe(id: 4, capturedAt: next, now: gap) == .waiting)
		#expect(frames.observe(id: 4, capturedAt: gap, now: gap.advanced(by: .seconds(2))) == .stalled)

		var empty = RecognitionFrameGate(now: start)
		#expect(empty.observe(id: 0, capturedAt: nil, now: start.advanced(by: .seconds(2))) == .waiting)
		#expect(empty.observe(id: 0, capturedAt: nil, now: start.advanced(by: .seconds(9))) == .stalled)

		// Match hold.
		let faceA = UUID()
		let faceB = UUID()
		var hold = RecognitionMatchHold()
		let initialHold = hold.consume(faceID: faceA, now: start, required: .seconds(2))
		let shortHold = hold.consume(faceID: faceA, now: start.advanced(by: .seconds(1)), required: .seconds(2))
		let fullHold = hold.consume(faceID: faceA, now: start.advanced(by: .seconds(2)), required: .seconds(2))
		let switchedHold = hold.consume(faceID: faceB, now: start.advanced(by: .seconds(3)), required: .seconds(2))
		let alternatingHold = hold.consume(faceID: faceA, now: start.advanced(by: .seconds(4)), required: .seconds(2))
		#expect(!initialHold)
		#expect(!shortHold)
		#expect(fullHold)
		#expect(!switchedHold)
		#expect(!alternatingHold)
		hold.reset()
		#expect(hold.faceID == nil)
		let afterResetHold = hold.consume(faceID: faceA, now: start.advanced(by: .seconds(10)), required: .seconds(2))
		let reversedTimeHold = hold.consume(faceID: faceA, now: start, required: .seconds(2))
		#expect(!afterResetHold)
		#expect(!reversedTimeHold)
	}

	@Test func releaseURLPolicyAndSessionConfigurationHardening() {
		for value in [
			"https://github.com/pearleseed/Gaze/releases/download/v1.2.3/Gaze-1.2.3-1-arm64.dmg",
			"https://github.com:443/pearleseed/Gaze/releases/download/v1.2.3/Gaze.dmg",
			"https://release-assets.githubusercontent.com/github-production-release-asset/123/Gaze.dmg",
			"https://objects.githubusercontent.com/github-production-release-asset/123",
		] {
			#expect(ReleaseURLPolicy.download(value) != nil)
		}

		for value in [
			"http://github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
			"https://gazeunlock.com/releases",
			"file:///Applications/Other.app",
			"javascript:alert(1)",
			"x-apple.systempreferences:privacy",
			"https://github.com.attacker.test/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
			"https://attacker.test/github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
			"https://github.com@attacker.test/file",
			"https://user:pass@github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
			"https://github.com:444/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
			"https://github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg#fragment",
			"//github.com/pearleseed/Gaze/releases/download/v1.0.0/Gaze.dmg",
			"https://127.0.0.1/file",
		] {
			#expect(ReleaseURLPolicy.download(value) == nil)
		}

		#expect(ReleaseURLPolicy.download(nil) == nil)
		#expect(
			ReleaseURLPolicy.download(
				"https://github.com/pearleseed/Gaze/releases/download/v1.0.0/" + String(repeating: "a", count: 4096)
			) == nil
		)

		let configuration = ReleaseURLPolicy.sessionConfiguration()
		#expect(configuration.urlCredentialStorage == nil && configuration.httpCookieStorage == nil)
		#expect(configuration.timeoutIntervalForResource == 20 && configuration.urlCache == nil)
	}

	@Test func antiSpoofGateFailsClosedOnInvalidOrUnavailableScores() throws {
		let sample = try Self.makeSample()
		for score: Float in [.nan, .infinity, -.infinity, -0.1, 1.1] {
			let gate = AntiSpoofGate { _, _ in score }
			#expect(gate.evaluate(sample) == .unavailable)
		}
		#expect(AntiSpoofGate(spoof: nil).evaluate(sample) == .unavailable)
		#expect(AntiSpoofGate { _, _ in nil }.evaluate(sample) == .unavailable)
		#expect(AntiSpoofGate { _, _ in 0.1 }.evaluate(sample) == .live)
		#expect(AntiSpoofGate { _, _ in 0.7 }.evaluate(sample) == .live)

		guard case .spoof = AntiSpoofGate(confidence: { _, _ in 0.95 }).evaluate(sample) else {
			Issue.record("Expected spoof decision at 0.95 confidence")
			return
		}
	}

	@Test func autofillReleaseGateRequiresApprovalFreshnessBudgetAndWritableField() async {
		var reads = 0
		var writes = 0
		var valid = true
		let read: () throws -> String? = {
			reads += 1
			return "synthetic-test-value"
		}
		let write: (String) -> Bool = { _ in
			writes += 1
			return true
		}

		let denied = await AutofillReleaseGate.release(
			isCurrent: { valid },
			approve: { false },
			resetBudget: { true },
			read: read,
			write: write
		)
		#expect(denied == .ownerRejected && reads == 0 && writes == 0)

		let switched = await AutofillReleaseGate.release(
			isCurrent: { valid },
			approve: {
				valid = false
				return true
			},
			resetBudget: { true },
			read: read,
			write: write
		)
		#expect(switched == .stale && reads == 0 && writes == 0)

		valid = true
		let budgetFailed = await AutofillReleaseGate.release(
			isCurrent: { valid },
			approve: { true },
			resetBudget: { false },
			read: read,
			write: write
		)
		#expect(budgetFailed == .budgetUnavailable && reads == 0)

		let changedOnRead = await AutofillReleaseGate.release(
			isCurrent: { valid },
			approve: { true },
			resetBudget: { true },
			read: {
				valid = false
				return try read()
			},
			write: write
		)
		#expect(changedOnRead == .stale && writes == 0)

		valid = true
		let writeDenied = await AutofillReleaseGate.release(
			isCurrent: { valid },
			approve: { true },
			resetBudget: { true },
			read: read,
			write: { _ in false }
		)
		#expect(writeDenied == .fieldNotWritable && writes == 0)

		let readFailed = await AutofillReleaseGate.release(
			isCurrent: { valid },
			approve: { true },
			resetBudget: { true },
			read: { throw InjectedFailure.injected },
			write: write
		)
		#expect(readFailed == .noPassword && writes == 0)

		let approved = await AutofillReleaseGate.release(
			isCurrent: { valid },
			approve: { true },
			resetBudget: { true },
			read: read,
			write: write
		)
		#expect(approved == .filled && writes == 1)

		let cancelled = Task { @MainActor in
			withUnsafeCurrentTask { $0?.cancel() }
			return await AutofillReleaseGate.release(
				isCurrent: { true },
				approve: { true },
				resetBudget: { true },
				read: read,
				write: write
			)
		}
		let cancelledResult = await cancelled.value
		#expect(cancelledResult == .stale && writes == 1)
	}
}
