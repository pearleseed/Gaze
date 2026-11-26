import AppKit
import CoreGraphics
import LocalAuthentication

/// `@unchecked Sendable` wrapper around `LAContext`: LocalAuthentication guarantees
/// `invalidate()` is safe to call from any thread (such as a task cancellation handler)
/// to cancel an in-flight `evaluatePolicy` request.
final class SendableLAContext: @unchecked Sendable {
	let context = LAContext()
	func invalidate() { context.invalidate() }
}

package struct AutofillConsoleSession: Equatable, Sendable {
	package let userID: UInt32
	package let identifier: String

	package init(userID: UInt32, identifier: String) {
		self.userID = userID
		self.identifier = identifier
	}

	package static func current() -> Self? {
		validated(CGSessionCopyCurrentDictionary() as? [String: Any], owner: geteuid())
	}

	package static func validated(_ values: [String: Any]?, owner: UInt32) -> Self? {
		guard let values,
			values[kCGSessionOnConsoleKey as String] as? Bool == true,
			values[kCGSessionLoginDoneKey as String] as? Bool == true,
			let userID = values[kCGSessionUserIDKey as String] as? UInt32, userID == owner,
			let identifier = values["CGSSessionUniqueSessionUUID"] as? String,
			UUID(uuidString: identifier) != nil
		else { return nil }
		if let locked = values["CGSSessionScreenIsLocked"] {
			guard let locked = locked as? Bool, !locked else { return nil }
		}
		return Self(userID: userID, identifier: identifier)
	}
}

@MainActor
package final class AutofillSessionLease {
	private let original: AutofillConsoleSession?
	private let current: () -> AutofillConsoleSession?
	private let workspace: NotificationCenter
	private let distributed: NotificationCenter
	private var workspaceObservers: [NSObjectProtocol] = []
	private var distributedObservers: [NSObjectProtocol] = []
	private var invalidated = false
	package var onInvalidation: (() -> Void)?

	package init(current: @escaping () -> AutofillConsoleSession? = AutofillConsoleSession.current,
		workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
		distributed: NotificationCenter = DistributedNotificationCenter.default()) {
		self.current = current
		self.original = current()
		self.workspace = workspace
		self.distributed = distributed
		for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
			NSWorkspace.sessionDidResignActiveNotification] {
			workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.invalidate() }
			})
		}
		for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
			distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.invalidate() }
			})
		}
	}

	package var isValid: Bool {
		guard !invalidated, original != nil, current() == original, !Task.isCancelled else {
			invalidate()
			return false
		}
		return true
	}

	package func invalidate() {
		guard !invalidated else { return }
		invalidated = true
		onInvalidation?()
	}

	isolated deinit {
		for observer in workspaceObservers { workspace.removeObserver(observer) }
		for observer in distributedObservers { distributed.removeObserver(observer) }
	}
}

@MainActor
package final class AutofillAttemptBudget {
	package struct State: Codable, Equatable, Sendable {
		package var attempts: Int

		package init(attempts: Int) {
			self.attempts = attempts
		}
	}

	package static let limit = 5
	private let load: () throws -> State?
	private let save: (State) throws -> Void
	private var storageFailed = false

	package init(load: @escaping () throws -> State?, save: @escaping (State) throws -> Void) {
		self.load = load
		self.save = save
	}

	package func reserve() -> Bool {
		guard !storageFailed else { return false }
		do {
			let state = try load() ?? State(attempts: 0)
			guard (0..<Self.limit).contains(state.attempts) else { return false }
			let next = State(attempts: state.attempts + 1)
			try save(next)
			guard try load() == next else { storageFailed = true; return false }
			return true
		} catch {
			storageFailed = true
			return false
		}
	}

	package func resetAfterOwnerApproval() -> Bool {
		do {
			let next = State(attempts: 0)
			try save(next)
			guard try load() == next else { storageFailed = true; return false }
			storageFailed = false
			return true
		} catch {
			storageFailed = true
			return false
		}
	}
}

@MainActor
package enum AutofillOwnerApproval {
	package static func authorize(session: AutofillSessionLease, reason: String) async -> Bool {
		guard session.isValid else { return false }
		let box = SendableLAContext()
		box.context.touchIDAuthenticationAllowableReuseDuration = 0
		box.context.localizedFallbackTitle = "Use Password…"
		session.onInvalidation = { box.invalidate() }
		defer {
			session.onInvalidation = nil
			box.invalidate()
		}
		return await withTaskCancellationHandler {
			do {
				let approved = try await box.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
				return approved && session.isValid && !Task.isCancelled
			} catch { return false }
		} onCancel: {
			box.invalidate()
		}
	}
}

@MainActor
package enum AutofillReleaseGate {
	package enum Result: Equatable, Sendable {
		case filled, ownerRejected, stale, budgetUnavailable, noPassword, fieldNotWritable
	}

	package static func release(isCurrent: () -> Bool, approve: () async -> Bool,
		resetBudget: () -> Bool, read: () throws -> String?, write: (String) -> Bool) async -> Result {
		guard !Task.isCancelled, isCurrent() else { return .stale }
		guard await approve() else { return .ownerRejected }
		guard !Task.isCancelled, isCurrent() else { return .stale }
		guard resetBudget() else { return .budgetUnavailable }
		guard !Task.isCancelled, isCurrent() else { return .stale }
		let password: String
		do {
			guard let stored = try read(), !stored.isEmpty else { return .noPassword }
			password = stored
		} catch { return .noPassword }
		guard !Task.isCancelled, isCurrent() else { return .stale }
		return write(password) ? .filled : .fieldNotWritable
	}
}
