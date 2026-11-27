import AppKit
import CoreGraphics
import Foundation
import GazeCore
import GazeSecurity
import Testing

@Suite("Lock Screen Password Submission, Budget, Keystrokes & Session Validation")
@MainActor
struct LockScreenSecurityTests {
	private enum HarnessError: Error {
		case vaultUnavailable
		case preparationFailed
	}

	@MainActor
	private final class SubmissionHarness {
		var session: LockedConsoleSession? = LockedConsoleSession(
			userID: 501,
			identifier: "00000000-0000-0000-0000-000000000001"
		)
		var enabled = true
		var authorized = true
		var verified = true
		var executionPolicy = UnlockExecutionPolicy.normal
		var password: String? = "dummy-password"
		var reads = 0
		var preparations = 0
		var events: [CGEvent] = []
		var onRead: (() throws -> Void)?
		var onPrepare: (() throws -> Void)?
		var onPost: (() -> Void)?

		func submit() throws {
			try LockScreenPasswordSubmission.submit(
				readPassword: {
					self.reads += 1
					try self.onRead?()
					return self.password
				},
				currentSession: { self.session },
				isEnabled: { self.enabled },
				canPost: { self.authorized },
				isVerified: { self.verified },
				executionPolicy: executionPolicy,
				prepare: { password in
					self.preparations += 1
					try self.onPrepare?()
					return try Keystrokes.passwordEvents(password)
				},
				post: { event in
					self.events.append(event)
					self.onPost?()
				}
			)
		}
	}

	private func payload(_ event: CGEvent) -> [UniChar] {
		var count = 0
		event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
		var units = [UniChar](repeating: 0, count: count)
		event.keyboardGetUnicodeString(maxStringLength: count, actualStringLength: &count, unicodeString: &units)
		return units
	}

	@Test func passwordReplaySafetyOptInAndRevocation() throws {
		let suite = "com.pearleseed.Tests.UnlockConsent.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(!PasswordReplaySafety.isEnabled(in: defaults))
		defaults.set("keystroke", forKey: "unlockBackend")
		#expect(throws: (any Error).self) {
			try PasswordReplaySafety.requireEnabled(in: defaults)
		}

		PasswordReplaySafety.setEnabled(true, in: defaults)
		try PasswordReplaySafety.requireEnabled(in: defaults)
		let reloaded = try #require(UserDefaults(suiteName: suite))
		#expect(PasswordReplaySafety.isEnabled(in: reloaded))

		PasswordReplaySafety.setEnabled(false, in: defaults)
		#expect(throws: (any Error).self) {
			try PasswordReplaySafety.requireEnabled(in: defaults)
		}
	}

	@Test func executionPolicyScanningAndLaunchFlags() {
		for selected in [false, true] {
			for replay in [false, true] {
				#expect(
					UnlockExecutionPolicy.scanOnly.permitsScanning(
						passwordReplayEnabled: replay,
						keystrokeSelected: selected
					)
				)
				#expect(
					!UnlockExecutionPolicy.uiReview.permitsScanning(
						passwordReplayEnabled: replay,
						keystrokeSelected: selected
					)
				)
				#expect(
					UnlockExecutionPolicy.normal.permitsScanning(
						passwordReplayEnabled: replay,
						keystrokeSelected: selected
					) == (replay && selected)
				)
			}
		}

		#expect(UnlockExecutionPolicy(arguments: []) == .normal)
		#expect(UnlockExecutionPolicy(arguments: ["--ui-review"]) == .uiReview)
		#expect(UnlockExecutionPolicy(arguments: ["--ui-review", "--scan-only"]) == .scanOnly)
		#expect(!UnlockExecutionPolicy.scanOnly.permitsAutomaticLocking)
		#expect(UnlockExecutionPolicy.scanOnly.permitsLockObservation)
		#expect(!UnlockExecutionPolicy.uiReview.permitsLockObservation)
	}

	@Test func submissionGuardsVerificationLifecycleAndBudget() throws {
		for policy in [UnlockExecutionPolicy.uiReview, .scanOnly] {
			let harness = SubmissionHarness()
			harness.executionPolicy = policy
			#expect(throws: (any Error).self) { try harness.submit() }
			#expect(harness.reads == 0 && harness.preparations == 0 && harness.events.isEmpty)
		}

		// Expired verification before submission.
		let unverified = SubmissionHarness()
		unverified.verified = false
		#expect(throws: (any Error).self) { try unverified.submit() }
		#expect(unverified.reads == 0 && unverified.events.isEmpty)

		// Verification expiring during credential read.
		let expireRead = SubmissionHarness()
		expireRead.onRead = { expireRead.verified = false }
		#expect(throws: (any Error).self) { try expireRead.submit() }
		#expect(expireRead.preparations == 0 && expireRead.events.isEmpty)

		// Verification expiring during event preparation.
		let expirePrepare = SubmissionHarness()
		expirePrepare.onPrepare = { expirePrepare.verified = false }
		#expect(throws: (any Error).self) { try expirePrepare.submit() }
		#expect(expirePrepare.events.isEmpty)

		// Verification expiring after event boundary 1...3 stops remaining input.
		for boundary in 1...3 {
			let expirePost = SubmissionHarness()
			expirePost.onPost = {
				if expirePost.events.count == boundary { expirePost.verified = false }
			}
			#expect(throws: (any Error).self) { try expirePost.submit() }
			#expect(expirePost.events.count == boundary)
		}

		// Submission budget lifecycle.
		var budget = LockScreenSubmissionBudget()
		let firstReserve = budget.reserve()
		#expect(firstReserve)
		#expect(!budget.maySubmit)

		var repeatedBudget = LockScreenSubmissionBudget()
		_ = repeatedBudget.reserve()
		for _ in 0..<10 {
			let repeatedReserve = repeatedBudget.reserve()
			#expect(!repeatedReserve)
		}

		var resetBudget = LockScreenSubmissionBudget()
		_ = resetBudget.reserve()
		resetBudget.resetAfterVerifiedUnlock()
		let postResetReserve = resetBudget.reserve()
		let secondPostResetReserve = resetBudget.reserve()
		#expect(postResetReserve)
		#expect(!secondPostResetReserve)

		// Successful submission reads once and prepares before posting.
		let ok = SubmissionHarness()
		try ok.submit()
		#expect(ok.reads == 1 && ok.preparations == 1)
		#expect(ok.events.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp])
		#expect(ok.events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [0, 0, 36, 36])
		#expect(payload(ok.events[0]) == Array("dummy-password".utf16))
	}

	@Test func submissionRejectsUnsafeStatePasswordsAndCancellation() async throws {
		// State invalid before read.
		for change in ["unlocked", "disabled", "denied"] {
			let harness = SubmissionHarness()
			if change == "unlocked" { harness.session = nil }
			if change == "disabled" { harness.enabled = false }
			if change == "denied" { harness.authorized = false }
			#expect(throws: (any Error).self) { try harness.submit() }
			#expect(harness.reads == 0 && harness.events.isEmpty)
		}

		// State invalid during read.
		for change in ["unlocked", "session switched", "disabled", "denied", "vault error"] {
			let harness = SubmissionHarness()
			harness.onRead = {
				switch change {
				case "unlocked":
					harness.session = nil
				case "session switched":
					harness.session = LockedConsoleSession(
						userID: 501,
						identifier: "00000000-0000-0000-0000-000000000002"
					)
				case "disabled":
					harness.enabled = false
				case "denied":
					harness.authorized = false
				default:
					throw HarnessError.vaultUnavailable
				}
			}
			#expect(throws: (any Error).self) { try harness.submit() }
			#expect(harness.reads == 1 && harness.events.isEmpty)
			#expect(harness.preparations == 0)
		}

		// Missing, empty, or control-character password.
		for password in [nil, "", "dummy\npassword", "dummy\tpassword", "dummy\u{0}password"] {
			let harness = SubmissionHarness()
			harness.password = password
			#expect(throws: (any Error).self) { try harness.submit() }
			#expect(harness.events.isEmpty)
		}

		// Event preparation failure cannot submit Return.
		let prepFail = SubmissionHarness()
		prepFail.onPrepare = { throw HarnessError.preparationFailed }
		#expect(throws: (any Error).self) { try prepFail.submit() }
		#expect(prepFail.events.isEmpty)

		// Session change during event preparation blocks all events.
		let prepSessionChange = SubmissionHarness()
		prepSessionChange.onPrepare = { prepSessionChange.session = nil }
		#expect(throws: (any Error).self) { try prepSessionChange.submit() }
		#expect(prepSessionChange.events.isEmpty)

		// Mid-post state changes stop remaining events immediately.
		for change in ["session", "permission", "enabled"] {
			for boundary in 1...3 {
				let harness = SubmissionHarness()
				harness.onPost = {
					guard harness.events.count == boundary else { return }
					if change == "session" { harness.session = nil }
					if change == "permission" { harness.authorized = false }
					if change == "enabled" { harness.enabled = false }
				}
				#expect(throws: (any Error).self) { try harness.submit() }
				#expect(harness.events.count == boundary)
			}
		}

		// Cancelled task before credential read.
		let cancelBefore = SubmissionHarness()
		let taskBefore = Task { @MainActor in
			withUnsafeCurrentTask { $0?.cancel() }
			try cancelBefore.submit()
		}
		switch await taskBefore.result {
		case .success:
			Issue.record("Cancellation was ignored")
		case .failure(let error):
			#expect(error is CancellationError)
		}
		#expect(cancelBefore.reads == 0 && cancelBefore.events.isEmpty)

		// Cancellation during credential read prevents posting.
		let cancelDuring = SubmissionHarness()
		cancelDuring.onRead = { withUnsafeCurrentTask { $0?.cancel() } }
		let taskDuring = Task { @MainActor in try cancelDuring.submit() }
		switch await taskDuring.result {
		case .success:
			Issue.record("Cancellation during read was ignored")
		case .failure(let error):
			#expect(error is CancellationError)
		}
		#expect(cancelDuring.events.isEmpty)
	}

	@Test func keystrokesAndConsoleSessionValidation() throws {
		#expect(throws: (any Error).self) {
			_ = try Keystrokes.passwordEvents("dummy", makeSource: { nil })
		}

		for failedEvent in 1...4 {
			var calls = 0
			#expect(throws: (any Error).self) {
				_ = try Keystrokes.passwordEvents(
					"dummy",
					makeEvent: { source, key, down in
						calls += 1
						return calls == failedEvent
							? nil
							: CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
					}
				)
			}
			#expect(calls == failedEvent)
		}

		let cleanEvents = try Keystrokes.passwordEvents(
			"dummy",
			makeEvent: { source, key, down in
				let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
				event?.flags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskAlphaShift]
				event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
				return event
			}
		)
		#expect(cleanEvents.allSatisfy { $0.flags.isEmpty })
		#expect(cleanEvents.allSatisfy { $0.getIntegerValueField(.keyboardEventAutorepeat) == 0 })

		for text in ["dummy-密码-🔐", "dummy-e\u{301}-👩‍💻", String(repeating: "dummy-long-", count: 30)] {
			let events = try Keystrokes.passwordEvents(text)
			#expect(payload(events[0]) == Array(text.utf16))
		}

		let valid: [String: Any] = [
			"CGSSessionScreenIsLocked": true,
			kCGSessionOnConsoleKey as String: true,
			kCGSessionLoginDoneKey as String: true,
			kCGSessionUserIDKey as String: NSNumber(value: 501),
			"CGSSessionUniqueSessionUUID": "00000000-0000-0000-0000-000000000001",
		]
		#expect(
			LockedConsoleSession.validated(valid, owner: 501)
				== LockedConsoleSession(userID: 501, identifier: "00000000-0000-0000-0000-000000000001")
		)

		var invalidUUID = valid
		invalidUUID["CGSSessionUniqueSessionUUID"] = "invalid"
		#expect(LockedConsoleSession.validated(invalidUUID, owner: 501) == nil)

		for key in valid.keys.sorted() {
			var incomplete = valid
			incomplete.removeValue(forKey: key)
			#expect(LockedConsoleSession.validated(incomplete, owner: 501) == nil)
		}

		#expect(LockedConsoleSession.validated(valid, owner: 502) == nil)
		var background = valid
		background[kCGSessionOnConsoleKey as String] = false
		#expect(LockedConsoleSession.validated(background, owner: 501) == nil)
		#expect(LockedConsoleSession.validated(nil, owner: 501) == nil)
	}
}
