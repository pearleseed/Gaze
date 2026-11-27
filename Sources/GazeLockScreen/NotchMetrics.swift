import AppKit

/// The physical notch's position and size.
///
/// Measured rather than hardcoded: notch dimensions differ between MacBook Air and Pro and
/// across sizes, and a capsule that is a few points wider than the cutout reads as a
/// floating pill rather than as the notch itself growing.
package enum NotchMetrics {

	package static func panelFrame(size: CGSize, screenFrame: CGRect, scale: CGFloat) -> CGRect {
		let left = floor((screenFrame.width - size.width) * scale / 2) / scale
		let right = ceil((screenFrame.width + size.width) * scale / 2) / scale
		let height = ceil(size.height * scale) / scale
		return CGRect(
			x: screenFrame.minX + left,
			y: screenFrame.maxY - height,
			width: right - left,
			height: height)
	}

	/// Width of the camera housing, in points, or nil on a screen without one.
	///
	/// Derived from the two menu bar fragments either side of the cutout: macOS reports
	/// those as auxiliary areas, and whatever lies between them is the notch.
	package static func width(on screen: NSScreen) -> CGFloat? {
		guard
			let left = screen.auxiliaryTopLeftArea,
			let right = screen.auxiliaryTopRightArea
		else { return nil }
		let gap = right.minX - left.maxX
		return gap > 0 ? gap : nil
	}

	/// Height of the notch — the menu bar's safe area inset.
	package static func height(on screen: NSScreen) -> CGFloat {
		let inset = screen.safeAreaInsets.top
		return inset > 0 ? inset : screen.frame.maxY - screen.visibleFrame.maxY
	}

	/// True when this screen physically has a notch.
	package static func hasNotch(on screen: NSScreen) -> Bool {
		width(on: screen) != nil
	}

	/// Where moving the pointer asks Gaze to look again on a locked screen: a band across
	/// the top centre of the display, a little wider and taller than the panel's housing
	/// so it can be hit without aiming. Screens without a notch get the same band, at the
	/// top centre where the panel appears.
	package static func hoverZone(screenFrame: CGRect, cutoutWidth: CGFloat?, notchHeight: CGFloat) -> CGRect {
		let width = max((cutoutWidth ?? 180) * 1.56, 240) + 40
		let height = max(notchHeight, 24) + 16
		return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
	}

	package static func hoverZone(on screen: NSScreen) -> CGRect {
		hoverZone(screenFrame: screen.frame, cutoutWidth: width(on: screen), notchHeight: height(on: screen))
	}

	/// Inclusive on every edge: a pointer pushed against the top of the display reports
	/// exactly the screen's `maxY`, which `CGRect.contains` would leave out.
	package static func zone(_ zone: CGRect, includes point: CGPoint) -> Bool {
		point.x >= zone.minX && point.x <= zone.maxX && point.y >= zone.minY && point.y <= zone.maxY
	}

	/// Whether the pointer is over the notch area of any display right now.
	@MainActor
	package static func pointerIsInHoverZone() -> Bool {
		let point = NSEvent.mouseLocation
		return NSScreen.screens.contains { zone(hoverZone(on: $0), includes: point) }
	}

	/// The rectangle the notch itself occupies, in screen coordinates.
	package static func frame(on screen: NSScreen) -> NSRect? {
		guard let width = width(on: screen) else { return nil }
		let height = height(on: screen)
		return NSRect(
			x: screen.frame.midX - width / 2,
			y: screen.frame.maxY - height,
			width: width,
			height: height)
	}
}
