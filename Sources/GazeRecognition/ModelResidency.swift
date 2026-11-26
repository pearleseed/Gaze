import Foundation
import Synchronization

/// Dropped after idleness so Gaze doesn't pin Core ML weights forever.
package protocol IdleUnloadable: AnyObject, Sendable {
	func unloadIfIdle(for interval: TimeInterval)
}

/// One reloadable model. Two mutexes: `state` guards only the stored reference and is
/// never held for more than a pointer swap, so `ifLoaded` on the main thread can
/// never wait behind a load; `loadMutex` serialises loads, which can take seconds
/// while Core ML compiles for the Neural Engine. Predictions run unlocked against
/// a local strong reference.
package final class ModelSlot<Model>: IdleUnloadable, Sendable {
	/// `@unchecked Sendable` because `Model` wraps non-Sendable Core ML handles (`MLModel`);
	/// all reads/writes of `value` and `lastUse` are strictly serialized by `state`.
	private struct State: @unchecked Sendable {
		var value: Model?
		var lastUse = Date()
	}

	private let state: Mutex<State>
	private let loadMutex = Mutex<Void>(())
	private let load: @Sendable () -> Model?

	package init(load: @escaping @Sendable () -> Model?, initial: Model? = nil) {
		self.load = load
		self.state = Mutex(State(value: initial))
		ModelResidency.register(self)
	}

	private func current(stamp: Bool) -> Model? {
		state.withLock { state in
			if stamp, state.value != nil { state.lastUse = Date() }
			return state.value
		}
	}

	/// The loaded model, loading it first if needed. Off the main thread only.
	private func loaded() -> Model? {
		if let model = current(stamp: true) { return model }
		return loadMutex.withLock { _ in
			// Someone else may have finished loading while this caller waited.
			if let model = current(stamp: true) { return model }
			guard let model = load() else { return nil }
			state.withLock { state in
				state.value = model
				state.lastUse = Date()
			}
			return model
		}
	}

	/// Loads when needed, stamps use, runs the body unlocked. Nil when loading fails.
	package func withModel<R>(_ body: (Model) throws -> R) rethrows -> R? {
		guard let model = loaded() else { return nil }
		return try body(model)
	}

	/// Runs the body only if the model is already loaded; never loads and never waits
	/// for a load. For callers on the main thread.
	package func ifLoaded<R>(_ body: (Model) throws -> R) rethrows -> R? {
		guard let model = current(stamp: true) else { return nil }
		return try body(model)
	}

	/// Loads when unloaded (lock-screen path calls this at lock and wake).
	package func preload() {
		_ = loaded()
	}

	package func unloadIfIdle(for interval: TimeInterval) {
		state.withLock { state in
			if Date().timeIntervalSince(state.lastUse) >= interval { state.value = nil }
		}
	}
}

/// One background sweep unloads every registered slot idle past the limit.
package enum ModelResidency {
	/// 30 minutes. Shorter reloaded the models on nearly every lock, and each reload
	/// can make Core ML rebuild them for the Neural Engine and write to disk; longer
	/// kept about 80 MB of weights in memory for hours of not locking.
	package static let idleLimit: TimeInterval = 30 * 60

	/// `@unchecked Sendable` for the `DispatchSourceTimer` handle; all mutations are
	/// serialized by `state`.
	private struct State: @unchecked Sendable {
		var slots: [any IdleUnloadable] = []
		var timer: DispatchSourceTimer?
	}

	private static let state = Mutex(State())

	package static func register(_ slot: any IdleUnloadable) {
		state.withLock { state in
			state.slots.append(slot)
			guard state.timer == nil else { return }
			let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
			t.schedule(deadline: .now() + 300, repeating: 300)
			t.setEventHandler { reap() }
			t.resume()
			state.timer = t
		}
	}

	private static func reap() {
		let current = state.withLock { $0.slots }
		for slot in current { slot.unloadIfIdle(for: idleLimit) }
	}
}
