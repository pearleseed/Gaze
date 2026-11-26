import AppKit
import CoreGraphics
import GazeCore
import GazeDesign
import GazeLockScreen
import MetalKit
import Testing

@Suite("Render Cache & Metal Redraw Efficiency")
@MainActor
struct RenderCacheTests {

	@Test func glowCacheKeyMatchesIdenticalInputsAndInvalidatesOnDimensionScaleOrNotchChange() {
		let notch = CGRect(x: 656, y: 950, width: 200, height: 32)
		let base = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 1512, height: 982),
			scale: 2.0,
			notch: notch
		)
		let identical = LockScreenLight.GlowCacheKey(
			width: 1512,
			height: 982,
			scale: 2.0,
			notchRect: notch
		)

		#expect(base == identical)
		#expect(base.hashValue == identical.hashValue)

		// Width change invalidates
		let wider = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 1728, height: 982),
			scale: 2.0,
			notch: notch
		)
		#expect(wider != base)

		// Height change invalidates
		let taller = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 1512, height: 1117),
			scale: 2.0,
			notch: notch
		)
		#expect(taller != base)

		// Backing scale change invalidates
		let scaled = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 1512, height: 982),
			scale: 1.0,
			notch: notch
		)
		#expect(scaled != base)

		// Notch rect position/size/presence change invalidates
		let movedNotch = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 1512, height: 982),
			scale: 2.0,
			notch: CGRect(x: 660, y: 950, width: 200, height: 32)
		)
		let resizedNotch = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 1512, height: 982),
			scale: 2.0,
			notch: CGRect(x: 656, y: 946, width: 200, height: 36)
		)
		let noNotch = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 1512, height: 982),
			scale: 2.0,
			notch: nil
		)
		#expect(movedNotch != base)
		#expect(resizedNotch != base)
		#expect(noNotch != base)
	}

	@Test func glowCacheHitsOnRepeatAndEvictsOldestBeyondTwoEntries() throws {
		var renderCount = 0
		let cache = LockScreenLight.GlowCache(maxEntries: 2) { key in
			renderCount += 1
			return LockScreenLight.renderGlowImage(for: key)
		}

		let primary = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 320, height: 200),
			scale: 2.0,
			notch: CGRect(x: 110, y: 180, width: 100, height: 20)
		)
		let external = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 400, height: 240),
			scale: 1.0,
			notch: nil
		)
		let third = LockScreenLight.GlowCacheKey(
			size: CGSize(width: 500, height: 300),
			scale: 2.0,
			notch: nil
		)

		let img1 = try #require(cache.image(for: primary))
		#expect(renderCount == 1)
		#expect(img1.width == 640)
		#expect(img1.height == 400)
		#expect(cache.count == 1)

		// Repeat hit reuses cached CGImage without re-rendering
		let img1Repeat = try #require(cache.image(for: primary))
		#expect(renderCount == 1)
		#expect(img1Repeat === img1)

		// Second distinct display entry fits in 2-entry cache
		_ = try #require(cache.image(for: external))
		#expect(renderCount == 2)
		#expect(cache.count == 2)

		// Third distinct entry evicts oldest (primary, since external was accessed more recently)
		_ = try #require(cache.image(for: third))
		#expect(renderCount == 3)
		#expect(cache.count == 2)
		#expect(cache.cachedImage(for: primary) == nil)
		#expect(cache.cachedImage(for: external) != nil)
		#expect(cache.cachedImage(for: third) != nil)

		// Also verify LockScreenLight's shared static cache helper works and stays bounded
		LockScreenLight.clearGlowCacheForTesting()
		defer { LockScreenLight.clearGlowCacheForTesting() }
		#expect(LockScreenLight.glowCacheCountForTesting == 0)
		let shared1 = try #require(LockScreenLight.cachedGlowImage(for: primary))
		let shared1Repeat = try #require(LockScreenLight.cachedGlowImage(for: primary))
		#expect(shared1 === shared1Repeat)
		#expect(LockScreenLight.glowCacheCountForTesting == 1)
	}

	@Test func pausedRenderStateDetectsChangesAcrossAllFields() {
		let base = GazeCompanionRenderer.PausedRenderState(
			revision: 1,
			angle: 0.25,
			material: .charcoal,
			opacity: 0.68
		)
		let identical = GazeCompanionRenderer.PausedRenderState(
			revision: 1,
			angle: 0.25,
			material: .charcoal,
			opacity: 0.68
		)
		#expect(base == identical)

		#expect(GazeCompanionRenderer.PausedRenderState(revision: 2, angle: 0.25, material: .charcoal, opacity: 0.68) != base)
		#expect(GazeCompanionRenderer.PausedRenderState(revision: 1, angle: 0.5, material: .charcoal, opacity: 0.68) != base)
		#expect(GazeCompanionRenderer.PausedRenderState(revision: 1, angle: 0.25, material: .pearl, opacity: 0.68) != base)
		#expect(GazeCompanionRenderer.PausedRenderState(revision: 1, angle: 0.25, material: .ink, opacity: 0.68) != base)
		#expect(GazeCompanionRenderer.PausedRenderState(revision: 1, angle: 0.25, material: .charcoal, opacity: 1.0) != base)
	}

	@Test func pausedRendererSkipsRedundantDrawsForUnchangedStateAndRedrawsOnChange() {
		let coordinator = GazeCompanionRenderer.Coordinator()
		let pose: (TimeInterval) -> GazeCompanionPose = { _ in GazeCompanionPose() }

		let initial = GazeCompanionRenderer.PausedRenderState(
			revision: 0,
			angle: 0.0,
			material: .charcoal,
			opacity: 0.68
		)

		// First paused draw must proceed
		#expect(coordinator.shouldRedrawWhenPaused(for: initial) == true)
		// Unchanged repeats must skip
		#expect(coordinator.shouldRedrawWhenPaused(for: initial) == false)
		#expect(coordinator.shouldRedrawWhenPaused(for: initial) == false)

		// Each field change triggers exactly one redraw
		let changedAngle = GazeCompanionRenderer.PausedRenderState(revision: 0, angle: 0.4, material: .charcoal, opacity: 0.68)
		#expect(coordinator.shouldRedrawWhenPaused(for: changedAngle) == true)
		#expect(coordinator.shouldRedrawWhenPaused(for: changedAngle) == false)

		let changedMaterial = GazeCompanionRenderer.PausedRenderState(revision: 0, angle: 0.4, material: .pearl, opacity: 0.68)
		#expect(coordinator.shouldRedrawWhenPaused(for: changedMaterial) == true)
		#expect(coordinator.shouldRedrawWhenPaused(for: changedMaterial) == false)

		let changedOpacity = GazeCompanionRenderer.PausedRenderState(revision: 0, angle: 0.4, material: .pearl, opacity: 1.0)
		#expect(coordinator.shouldRedrawWhenPaused(for: changedOpacity) == true)
		#expect(coordinator.shouldRedrawWhenPaused(for: changedOpacity) == false)

		let changedRevision = GazeCompanionRenderer.PausedRenderState(revision: 1, angle: 0.4, material: .pearl, opacity: 1.0)
		#expect(coordinator.shouldRedrawWhenPaused(for: changedRevision) == true)
		#expect(coordinator.shouldRedrawWhenPaused(for: changedRevision) == false)

		// Verify live TransparentFaceView + Coordinator redraw trigger count
		let view = TransparentFaceView(frame: CGRect(x: 0, y: 0, width: 120, height: 120), device: MTLCreateSystemDefaultDevice())
		view.delegate = coordinator

		let renderer1 = GazeCompanionRenderer(
			pose: pose,
			running: false,
			revision: 0,
			angle: 0.0,
			material: .charcoal,
			opacity: 0.68,
			failure: { _ in }
		)
		renderer1.applyStateForTesting(to: view, coordinator: coordinator)
		#expect(coordinator.pausedDrawTriggerCountForTesting == 1)

		renderer1.applyStateForTesting(to: view, coordinator: coordinator)
		renderer1.applyStateForTesting(to: view, coordinator: coordinator)
		#expect(coordinator.pausedDrawTriggerCountForTesting == 1)

		// Running then settling again forces one fresh paused frame
		let runningRenderer = GazeCompanionRenderer(
			pose: pose,
			running: true,
			revision: 0,
			angle: 0.0,
			material: .charcoal,
			opacity: 0.68,
			failure: { _ in }
		)
		runningRenderer.applyStateForTesting(to: view, coordinator: coordinator)
		#expect(coordinator.pausedDrawTriggerCountForTesting == 1)

		renderer1.applyStateForTesting(to: view, coordinator: coordinator)
		#expect(coordinator.pausedDrawTriggerCountForTesting == 2)
		renderer1.applyStateForTesting(to: view, coordinator: coordinator)
		#expect(coordinator.pausedDrawTriggerCountForTesting == 2)
	}

	@Test func transparentFaceViewPausesWhenDetachedHiddenOrMiniaturizedAndResumesOnExpose() {
		let view = TransparentFaceView(frame: CGRect(x: 0, y: 0, width: 160, height: 160), device: MTLCreateSystemDefaultDevice())
		view.wantsContinuousRendering = true
		#expect(view.isPaused == true)

		let window = NSWindow(
			contentRect: CGRect(x: 0, y: 0, width: 160, height: 160),
			styleMask: [.titled, .closable, .miniaturizable],
			backing: .buffered,
			defer: false
		)
		defer {
			window.orderOut(nil)
			window.contentView = nil
		}

		window.contentView = view
		// Before orderFront, window.isVisible == false so continuous rendering must remain paused.
		#expect(window.isVisible == false)
		#expect(view.isPaused == true)

		window.orderFront(nil)
		RunLoop.main.run(until: Date().addingTimeInterval(0.05))
		if window.isVisible && !window.isMiniaturized {
			#expect(view.isPaused == false)
		}

		// Ordering out makes window invisible -> must pause continuous rendering.
		window.orderOut(nil)
		NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
		RunLoop.main.run(until: Date().addingTimeInterval(0.02))
		#expect(view.isPaused == true)

		// Re-exposing window via orderFront + notification must resume continuous rendering.
		window.orderFront(nil)
		NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: window)
		RunLoop.main.run(until: Date().addingTimeInterval(0.02))
		if window.isVisible && !window.isMiniaturized {
			#expect(view.isPaused == false)
		}

		// Confirm observers are registered for all required wake/screen/window lifecycle events.
		let registered = Set(view.observedNotificationNamesForTesting)
		#expect(registered.contains(NSWindow.didChangeOcclusionStateNotification))
		#expect(registered.contains(NSWindow.didChangeScreenNotification))
		#expect(registered.contains(NSWorkspace.screensDidWakeNotification))
		#expect(registered.contains(NSWindow.didDeminiaturizeNotification))
		#expect(registered.contains(NSWindow.didExposeNotification))
	}
}
