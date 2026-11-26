import AppKit
import MetalKit
import SwiftUI

package struct SoftFaceUniforms {
	package var pose: SIMD4<Float>
	package var expression: SIMD4<Float>
	package var transform: SIMD4<Float>
	package var viewport: SIMD4<Float>

	package init(pose: GazeCompanionPose, size: CGSize, angle: Double = 0, opacity: Float = 0.68, material: GazeCompanionMaterial = .charcoal) {
		self.pose = SIMD4(Float(pose.face.turn), Float(pose.face.nod), Float(pose.face.eyesOpen), Float(pose.face.mouthOpen))
		expression = SIMD4(Float(pose.face.expression), Float(pose.face.gaze), material == .pearl ? 1 : 0, material == .ink ? 0.48 : 1)
		transform = SIMD4(Float(pose.roll), Float(pose.stretch), Float(pose.lift), Float(pose.drift))
		viewport = SIMD4(Float(size.width), Float(size.height), Float(angle), opacity)
	}
}

enum SoftFaceError: LocalizedError {
	case unavailable, shaderMissing, textureUnavailable, commandUnavailable
	var errorDescription: String? {
		switch self {
		case .unavailable: "Metal is unavailable on this Mac."
		case .shaderMissing: "The 3D face shader could not be loaded."
		case .textureUnavailable: "The 3D render target could not be created."
		case .commandUnavailable: "The 3D frame could not be submitted."
		}
	}
}

final class SoftFaceGPU {
	let device: MTLDevice
	let queue: MTLCommandQueue
	let pipeline: MTLRenderPipelineState
	@MainActor private static var cached: SoftFaceGPU?

	@MainActor static func shared() throws -> SoftFaceGPU {
		if let cached { return cached }
		let gpu = try SoftFaceGPU()
		cached = gpu
		return gpu
	}

	init() throws {
		guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw SoftFaceError.unavailable }
		self.device = device
		self.queue = queue
		let library = try device.makeLibrary(source: GazeCompanionShader.source, options: nil)
		guard let vertex = library.makeFunction(name: "faceVertex"), let fragment = library.makeFunction(name: "faceFragment") else { throw SoftFaceError.shaderMissing }
		let descriptor = MTLRenderPipelineDescriptor()
		descriptor.vertexFunction = vertex
		descriptor.fragmentFunction = fragment
		descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
		pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
	}

	func encode(_ uniforms: SoftFaceUniforms, pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) throws {
		guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SoftFaceError.commandUnavailable }
		var uniforms = uniforms
		encoder.setRenderPipelineState(pipeline)
		encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SoftFaceUniforms>.stride, index: 0)
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		encoder.endEncoding()
	}
}

private final class ObserverStore: @unchecked Sendable {
	private let lock = NSLock()
	private var entries: [(NotificationCenter, NSObjectProtocol)] = []

	func replace(with next: [(NotificationCenter, NSObjectProtocol)]) {
		lock.lock()
		let old = entries
		entries = next
		lock.unlock()
		for (centre, token) in old {
			centre.removeObserver(token)
		}
	}

	func removeAll() {
		replace(with: [])
	}

	var count: Int {
		lock.lock()
		defer { lock.unlock() }
		return entries.count
	}
}

package class TransparentFaceView: MTKView {
	private let localNotificationCenter: NotificationCenter
	private let workspaceNotificationCenter: NotificationCenter
	private let observerStore = ObserverStore()

	package init(
		frame frameRect: CGRect = .zero,
		device: MTLDevice? = nil,
		localNotificationCenter: NotificationCenter = .default,
		workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
	) {
		self.localNotificationCenter = localNotificationCenter
		self.workspaceNotificationCenter = workspaceNotificationCenter
		super.init(frame: frameRect, device: device)
	}

	required init(coder: NSCoder) {
		self.localNotificationCenter = .default
		self.workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
		super.init(coder: coder)
	}

	deinit {
		observerStore.removeAll()
	}

	override package var isOpaque: Bool { false }
	package var wantsContinuousRendering = false {
		didSet {
			guard wantsContinuousRendering != oldValue || isPaused == wantsContinuousRendering else { return }
			updateRenderingState()
		}
	}

	package func updateRenderingState() {
		let visibleInWindow = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
		let paused = !wantsContinuousRendering || !visibleInWindow
		let transition = isPaused != paused
		if transition { isPaused = paused }
		if enableSetNeedsDisplay != paused { enableSetNeedsDisplay = paused }
		if transition && visibleInWindow && paused { needsDisplay = true }
	}

	override package func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		matchBackingScale()
		updateRenderingState()
		observeDisplayChanges()
		if window != nil { restartRendering() }
	}

	package private(set) var observedNotificationNamesForTesting: [Notification.Name] = []
	package private(set) var restartRenderingCountForTesting = 0
	package var activeDisplayObserverCountForTesting: Int { observerStore.count }

	package func removeDisplayObservers() {
		observerStore.removeAll()
		observedNotificationNamesForTesting.removeAll()
	}

	/// Opening the lid shows the lock screen panel while the displays are still waking.
	/// A face view made then got no drawable and a display link bound to no screen, so it
	/// stayed blank for the whole scan while the text around it updated (issue #100).
	/// Starting over once the window is actually on a live screen fixes both.
	private func observeDisplayChanges() {
		removeDisplayObservers()
		guard let window else { return }
		let restart: @Sendable (Notification) -> Void = { [weak self] _ in
			MainActor.assumeIsolated { self?.restartRendering() }
		}
		let local = localNotificationCenter
		let workspace = workspaceNotificationCenter
		let registrations: [(NotificationCenter, Notification.Name, AnyObject?)] = [
			(local, NSWindow.didChangeOcclusionStateNotification, window),
			(local, NSWindow.didChangeScreenNotification, window),
			(local, NSWindow.didMiniaturizeNotification, window),
			(local, NSWindow.didDeminiaturizeNotification, window),
			(local, NSWindow.didExposeNotification, window),
			(workspace, NSWorkspace.screensDidWakeNotification, nil),
		]
		var names: [Notification.Name] = []
		let tokens: [(NotificationCenter, NSObjectProtocol)] = registrations.map { centre, name, object in
			names.append(name)
			return (centre, centre.addObserver(forName: name, object: object, queue: .main, using: restart))
		}
		observedNotificationNamesForTesting = names
		observerStore.replace(with: tokens)
	}

	package func restartRendering() {
		guard window != nil else { return }
		restartRenderingCountForTesting &+= 1
		matchBackingScale()
		updateRenderingState()
		if isPaused {
			if window?.isVisible == true, window?.isMiniaturized == false {
				needsDisplay = true
			}
		} else {
			// Re-arms the display link on whichever screen the window is on now.
			isPaused = true
			isPaused = false
		}
	}

	/// MTKView sizes its drawable as bounds × `layer.contentsScale`. The layer is
	/// created in `makeNSView`, before the view has a window, so its scale starts at
	/// 1 — and on the borderless lock-screen window it was never raised, which drew
	/// the companion at half resolution and let the compositor upscale it.
	private func matchBackingScale() {
		guard let scale = window?.backingScaleFactor, layer?.contentsScale != scale else { return }
		layer?.contentsScale = scale
		needsDisplay = true
	}

	override package func layout() {
		super.layout()
		updateRenderingState()
		if isPaused, window?.isVisible == true, window?.isMiniaturized == false {
			needsDisplay = true
		}
	}

	override package func viewWillDraw() {
		super.viewWillDraw()
		updateRenderingState()
	}

	override package func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		matchBackingScale()
		if isPaused, window?.isVisible == true, window?.isMiniaturized == false {
			needsDisplay = true
		}
	}
}

@MainActor
package struct GazeCompanionRenderer: NSViewRepresentable {
	/// Inputs that affect a paused companion frame; identical values skip redundant redraws.
	package struct PausedRenderState: Equatable, Sendable {
		package var revision: Int
		package var angle: Double
		package var material: GazeCompanionMaterial
		package var opacity: Float
		package var pose: GazeCompanionPose

		package init(
			revision: Int,
			angle: Double,
			material: GazeCompanionMaterial,
			opacity: Float,
			pose: GazeCompanionPose = GazeCompanionPose()
		) {
			self.revision = revision
			self.angle = angle
			self.material = material
			self.opacity = opacity
			self.pose = pose
		}
	}

	package let pose: (TimeInterval) -> GazeCompanionPose
	package let running: Bool
	package var revision: Int
	package var angle: Double
	package var material: GazeCompanionMaterial
	package var opacity: Float
	package var report: ((String) -> Void)?
	package var diagnosticContext: String
	package var failure: (String) -> Void

	package init(
		pose: @escaping (TimeInterval) -> GazeCompanionPose,
		running: Bool,
		revision: Int = 0,
		angle: Double = 0.0,
		material: GazeCompanionMaterial = .charcoal,
		opacity: Float = 0.68,
		report: ((String) -> Void)? = nil,
		diagnosticContext: String = "preview",
		failure: @escaping (String) -> Void
	) {
		self.pose = pose
		self.running = running
		self.revision = revision
		self.angle = angle
		self.material = material
		self.opacity = opacity
		self.report = report
		self.diagnosticContext = diagnosticContext
		self.failure = failure
	}

	package func makeCoordinator() -> Coordinator { Coordinator() }

	package func makeNSView(context: Context) -> MTKView {
		let view = TransparentFaceView()
		view.wantsLayer = true
		view.layer?.isOpaque = false
		view.colorPixelFormat = .bgra8Unorm
		view.framebufferOnly = true
		view.clearColor = MTLClearColorMake(0, 0, 0, 0)
		view.enableSetNeedsDisplay = true
		view.isPaused = true
		// The display's own rate, up to 120 on ProMotion. At 30 the face visibly stepped
		// next to everything else on screen animating at 60 or 120.
		view.preferredFramesPerSecond = min(120, max(60, NSScreen.main?.maximumFramesPerSecond ?? 60))
		view.setAccessibilityElement(false)
		do {
			context.coordinator.gpu = try SoftFaceGPU.shared()
			view.device = context.coordinator.gpu?.device
			view.delegate = context.coordinator
		} catch {
			Task { @MainActor in failure(error.localizedDescription) }
		}
		return view
	}

	package func updateNSView(_ view: MTKView, context: Context) {
		applyState(to: view, coordinator: context.coordinator)
	}

	package func applyStateForTesting(to view: MTKView, coordinator: Coordinator) {
		applyState(to: view, coordinator: coordinator)
	}

	private func applyState(to view: MTKView, coordinator: Coordinator) {
		coordinator.pose = pose
		coordinator.angle = angle
		coordinator.material = material
		coordinator.opacity = opacity
		coordinator.report = report
		coordinator.failure = failure
		if GazeRenderDiagnostics.enabled && running {
			if coordinator.diagnostics == nil || coordinator.diagnosticContext != diagnosticContext {
				coordinator.finishDiagnostics(in: view, reason: "contextChanged")
				coordinator.diagnostics = GazeRenderDiagnostics()
			}
		} else {
			coordinator.finishDiagnostics(in: view, reason: "paused")
			coordinator.diagnostics = nil
		}
		coordinator.diagnosticContext = diagnosticContext
		if coordinator.revision != revision {
			coordinator.revision = revision
			coordinator.frameTimes = []
		}
		if let faceView = view as? TransparentFaceView {
			faceView.wantsContinuousRendering = running
			faceView.updateRenderingState()
		}
		if running {
			coordinator.clearPausedRenderState()
		} else {
			let state = PausedRenderState(
				revision: revision,
				angle: angle,
				material: material,
				opacity: opacity,
				pose: pose(Date.timeIntervalSinceReferenceDate)
			)
			if coordinator.shouldRedrawWhenPaused(for: state) {
				coordinator.recordPausedDrawTriggerForTesting()
				view.needsDisplay = true
				if let window = view.window, window.isVisible, !window.isMiniaturized {
					view.draw()
				}
			}
		}
	}

	package static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
		coordinator.finishDiagnostics(in: view, reason: "removed")
		(view as? TransparentFaceView)?.removeDisplayObservers()
		view.isPaused = true
		view.delegate = nil
		coordinator.pose = nil
		coordinator.clearPausedRenderState()
	}

	@MainActor
	package final class Coordinator: NSObject, MTKViewDelegate {
		var gpu: SoftFaceGPU?
		var pose: ((TimeInterval) -> GazeCompanionPose)?
		var angle = 0.0
		var material = GazeCompanionMaterial.charcoal
		var opacity: Float = 0.68
		var report: ((String) -> Void)?
		var failure: ((String) -> Void)?
		var revision = -1
		var frameTimes: [Double] = []
		var diagnostics: GazeRenderDiagnostics?
		var diagnosticContext = "preview"
		let frameBudget = DispatchSemaphore(value: 2)
		private var missedFrames = 0
		private var lastReport = 0.0
		package private(set) var lastPausedRenderState: PausedRenderState?
		package private(set) var pausedDrawTriggerCountForTesting = 0

		package func clearPausedRenderState() {
			lastPausedRenderState = nil
		}

		package func shouldRedrawWhenPaused(for state: PausedRenderState) -> Bool {
			guard lastPausedRenderState != state else { return false }
			lastPausedRenderState = state
			return true
		}

		func recordPausedDrawTriggerForTesting() {
			pausedDrawTriggerCountForTesting &+= 1
		}

		func finishDiagnostics(in view: MTKView, reason: String) {
			if let summary = diagnostics?.finish() {
				GazeRenderDiagnostics.log(summary, context: diagnosticContext,
					windowVisible: view.window?.occlusionState.contains(.visible) == true, reason: reason)
			}
		}

		package func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
			if view.isPaused { view.needsDisplay = true }
		}

		package func draw(in view: MTKView) {
			let diagnosticStart = diagnostics != nil && !view.isPaused ? CACurrentMediaTime() : nil
			var outcome = GazeRenderDiagnostics.Outcome.unavailable
			var drawableSeconds = 0.0
			defer {
				if let diagnosticStart,
					let summary = diagnostics?.record(start: diagnosticStart, end: CACurrentMediaTime(), outcome: outcome,
						drawableSeconds: drawableSeconds) {
					GazeRenderDiagnostics.log(summary, context: diagnosticContext,
						windowVisible: view.window?.occlusionState.contains(.visible) == true)
				}
			}
			guard frameBudget.wait(timeout: .now()) == .success else {
				outcome = .busy
				return
			}
			let budget = frameBudget
			guard let gpu, let pose else { budget.signal(); return }
			let drawableStart = diagnosticStart != nil ? CACurrentMediaTime() : nil
			let currentDrawable = view.currentDrawable
			if let drawableStart { drawableSeconds = CACurrentMediaTime() - drawableStart }
			guard let drawable = currentDrawable,
				let pass = view.currentRenderPassDescriptor, let command = gpu.queue.makeCommandBuffer() else {
				budget.signal()
				// A paused view draws only when asked, so a frame lost here (no drawable
				// yet, as right after wake) would leave it blank. Ask again for a few seconds.
				if view.isPaused, missedFrames < 30 {
					missedFrames += 1
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view] in view?.needsDisplay = true }
				}
				return
			}
			missedFrames = 0
			let time = Date.timeIntervalSinceReferenceDate
			let uniforms = SoftFaceUniforms(pose: pose(time), size: view.drawableSize, angle: angle, opacity: opacity, material: material)
			do { try gpu.encode(uniforms, pass: pass, command: command) }
			catch {
				outcome = .failed
				budget.signal()
				view.isPaused = true
				let message = error.localizedDescription
				Task { @MainActor [weak self] in self?.failure?(message) }
				return
			}
			command.addCompletedHandler { _ in budget.signal() }
			command.present(drawable)
			command.commit()
			outcome = .submitted
			if !view.isPaused, report != nil {
				frameTimes.append(CACurrentMediaTime())
				if frameTimes.count > 240 { frameTimes.removeFirst(frameTimes.count - 240) }
				if time - lastReport > 1, frameTimes.count > 30 {
					lastReport = time
					let intervals = zip(frameTimes.dropFirst(), frameTimes).map { $0 - $1 }.sorted()
					let fps = Double(intervals.count) / intervals.reduce(0, +)
					let percentile = intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))] * 1000
					let text = String(format: "%.0f fps · p95 %.1f ms · render callbacks", fps, percentile)
					Task { @MainActor [weak self] in self?.report?(text) }
				}
			}
		}
	}
}
