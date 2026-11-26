import AppKit
import AVFoundation
import GazeCore

extension SettingsView {
	static var cameraAuthorized: Bool {
		if ProductCaptureDemo.isOn { return true }
		return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
	}
}

@MainActor
extension GazeBrand {
	/// The capture tool's fresh ad-hoc bundle gets a generic icon from Launch Services
	/// until it is indexed, so under capture it reads the Gaze icon file directly.
	static var appIcon: NSImage {
		if ProductCaptureDemo.isOn, let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
		   let icon = NSImage(contentsOf: url) {
			return icon
		}
		return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
	}
}
