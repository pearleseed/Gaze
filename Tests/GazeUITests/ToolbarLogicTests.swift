import AppKit
import SwiftUI
import Testing
@testable import GazeApp

@MainActor
private final class IsolatedToolbarWindow: NSWindow {
	var testKey = true
	var testPointer = CGPoint.zero
	override var isKeyWindow: Bool { testKey }
	override var mouseLocationOutsideOfEventStream: NSPoint { testPointer }
}

@Observable
@MainActor
private final class ToolbarSelection {
	var pane = SettingsPane.face
}

@Suite("Toolbar Picker Gaze, Selection, Tracking & Brand Icon")
@MainActor
struct ToolbarLogicTests {
	private func findControl(_ view: NSView) -> GazeToolbarControl? {
		if let control = view as? GazeToolbarControl { return control }
		return view.subviews.compactMap(findControl).first
	}

	private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
		let data = try #require(image.tiffRepresentation)
		return try #require(NSBitmapImageRep(data: data))
	}

	private func eyeCenter(_ bitmap: NSBitmapImageRep, dark: Bool) throws -> CGPoint {
		var horizontal = 0.0
		var vertical = 0.0
		var count = 0.0
		for row in 5..<18 {
			for column in 5..<18 {
				let color = try #require(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB))
				let weight = color.alphaComponent * max(0, dark ? 0.65 - color.redComponent : color.redComponent - 0.5)
				horizontal += Double(column) * weight
				vertical += Double(row) * weight
				count += weight
			}
		}
		#expect(count > 2)
		return CGPoint(x: horizontal / count, y: vertical / count)
	}

	@Test func toolbarGazeMotionInterpolationAndBounds() {
		var motion = GazeToolbarGaze()
		motion.retarget(CGPoint(x: 1, y: -1), at: 1)
		let interrupted = motion.value(at: 1.08)
		motion.retarget(CGPoint(x: -1, y: 0.5), at: 1.08)
		#expect(motion.value(at: 1.08) == interrupted)
		#expect(motion.value(at: 2) == CGPoint(x: -1, y: 0.5))

		for frame in 0...120 {
			let point = motion.value(at: 1.08 + Double(frame) / 120)
			#expect(abs(point.x) <= 1 && abs(point.y) <= 1)
		}

		let bounds = CGRect(x: 0, y: 0, width: 240, height: 32)
		#expect(GazeToolbarGaze.target(at: CGPoint(x: 100, y: 33), in: bounds, eyeCenter: .zero) == .zero)
		#expect(GazeToolbarGaze.target(at: CGPoint(x: 100, y: -1), in: bounds, eyeCenter: .zero) == .zero)
	}

	@Test func pickerSelectionHoverDragIsolationReduceMotionAndBrandIcons() throws {
		#expect(SettingsPane.toolbarPanes == [.face, .security, .apps, .notch, .general, .about])
		#expect(GazeBrand.menuBarIcon.isTemplate)

		for dark in [false, true] {
			let selection = ToolbarSelection()
			let host = NSHostingView(
				rootView: GazeSettingsPicker(
					selection: Binding(get: { selection.pane }, set: { selection.pane = $0 })
				)
				.fixedSize()
				.padding(24)
				.frame(width: 460, height: 100)
				.background(Color(nsColor: .windowBackgroundColor))
				.environment(\.colorScheme, dark ? .dark : .light)
			)
			host.frame = CGRect(x: 0, y: 0, width: 460, height: 100)
			let window = IsolatedToolbarWindow(
				contentRect: host.frame,
				styleMask: [.borderless],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
			window.contentView = host
			defer { window.contentView = nil }

			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

			let control = try #require(findControl(host))
			#expect(control.segmentCount == SettingsPane.toolbarPanes.count && control.trackingMode == .selectOne)
			#expect(control.selectedSegment == 0 && control.image(forSegment: 0)?.accessibilityDescription == "Unlock")
			let initialSize = control.intrinsicContentSize

			for index in SettingsPane.toolbarPanes.indices {
				#expect(control.toolTip(forSegment: index) == SettingsPane.toolbarPanes[index].title)
				control.selectedSegment = index
				control.sendAction(control.action, to: control.target)
				#expect(selection.pane == SettingsPane.toolbarPanes[index])
			}
			control.selectedSegment = 0
			control.sendAction(control.action, to: control.target)

			func event(
				_ type: NSEvent.EventType,
				point: CGPoint,
				in eventWindow: NSWindow? = nil
			) throws -> NSEvent {
				if type == .mouseExited {
					return try #require(
						NSEvent.enterExitEvent(
							with: type,
							location: control.convert(point, to: nil),
							modifierFlags: [],
							timestamp: ProcessInfo.processInfo.systemUptime,
							windowNumber: window.windowNumber,
							context: nil,
							eventNumber: 0,
							trackingNumber: 0,
							userData: nil
						)
					)
				}
				return try #require(
					NSEvent.mouseEvent(
						with: type,
						location: control.convert(point, to: nil),
						modifierFlags: [],
						timestamp: ProcessInfo.processInfo.systemUptime,
						windowNumber: (eventWindow ?? window).windowNumber,
						context: nil,
						eventNumber: 0,
						clickCount: 0,
						pressure: 0
					)
				)
			}

			control.mouseMoved(
				with: try event(.mouseMoved, point: CGPoint(x: control.bounds.maxX - 2, y: control.bounds.midY))
			)
			#expect(control.gaze.target.x > 0.9 && control.animationTimer != nil)
			control.advance(at: control.gaze.started + 1)
			#expect(control.animationTimer == nil)

			let target = control.gaze.target
			window.testKey = false
			control.mouseMoved(with: try event(.mouseMoved, point: .zero))
			#expect(control.gaze.target == target)

			window.testKey = true
			let other = NSWindow(
				contentRect: host.frame,
				styleMask: [.borderless],
				backing: .buffered,
				defer: false
			)
			other.isReleasedWhenClosed = false
			control.follow(try event(.mouseMoved, point: .zero, in: other))
			#expect(control.gaze.target == target)

			control.follow(
				try event(.leftMouseDragged, point: CGPoint(x: control.bounds.maxX - 2, y: control.bounds.maxY + 10))
			)
			#expect(control.gaze.target == .zero)
			control.advance(at: control.gaze.started + 1)
			#expect(control.animationTimer == nil)

			window.testPointer = control.convert(CGPoint(x: control.bounds.maxX - 2, y: control.bounds.midY), to: nil)
			control.beginFollowingDrag()
			control.advance()
			#expect(control.isTrackingDrag && control.gaze.target.x > 0.9)

			window.testPointer = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.maxY + 10), to: nil)
			control.advance()
			#expect(control.gaze.target == .zero)
			control.endFollowingDrag()
			control.advance(at: control.gaze.started + 1)
			#expect(!control.isTrackingDrag && control.animationTimer == nil)

			control.configure(dark: dark, reducedMotion: true, opaque: false)
			control.mouseMoved(
				with: try event(.mouseMoved, point: CGPoint(x: control.bounds.maxX - 2, y: control.bounds.midY))
			)
			#expect(control.gaze.target == .zero && control.animationTimer == nil)

			control.configure(dark: dark, reducedMotion: false, opaque: false)
			control.retarget(CGPoint(x: 1, y: 1))
			NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
			#expect(control.gaze.target == .zero && control.animationTimer == nil)

			control.retarget(CGPoint(x: -1, y: 0))
			control.mouseExited(with: try event(.mouseExited, point: .zero))
			#expect(control.gaze.target == .zero)
			control.advance(at: control.gaze.started + 1)
			#expect(control.intrinsicContentSize == initialSize)

			// Brand icon translucency, colour polarity and eye centroid tracking.
			let image = GazeBrand.toolbarIcon(dark: dark)
			let opaque = GazeBrand.toolbarIcon(dark: dark, opaque: true)
			let imageBitmap = try bitmap(image)
			let body = try #require(imageBitmap.colorAt(x: 11, y: 6)?.usingColorSpace(.deviceRGB))
			let opaqueBody = try #require(try bitmap(opaque).colorAt(x: 11, y: 6)?.usingColorSpace(.deviceRGB))
			#expect(body.alphaComponent < 0.96 && body.alphaComponent > 0.75)
			#expect(opaqueBody.alphaComponent > 0.99)
			#expect(dark ? body.redComponent > 0.75 : body.redComponent < 0.4)

			let neutralEyes = try eyeCenter(imageBitmap, dark: dark)
			let rightEyes = try eyeCenter(
				try bitmap(GazeBrand.toolbarIcon(dark: dark, gaze: CGPoint(x: 1, y: 0))),
				dark: dark
			)
			let upEyes = try eyeCenter(
				try bitmap(GazeBrand.toolbarIcon(dark: dark, gaze: CGPoint(x: 0, y: -1))),
				dark: dark
			)
			#expect(rightEyes.x - neutralEyes.x > 0.65)
			#expect(neutralEyes.y - upEyes.y > 0.4)

			control.retarget(CGPoint(x: 1, y: 1))
			control.removeFromSuperview()
			#expect(control.animationTimer == nil && control.gaze.target == .zero)
		}
	}
}
