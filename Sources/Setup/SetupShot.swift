import AppKit
import SwiftUI

/// A screenshot of Gaze or macOS for a setup page.
struct SetupShot: View {
	let name: String
	/// Width over height of the media, so it can be fitted without cropping.
	var aspectRatio: CGFloat = 16.0 / 10.0
	var cornerRadius: CGFloat = 14

	var body: some View {
		content
			.aspectRatio(aspectRatio, contentMode: .fit)
			.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
					.strokeBorder(.white.opacity(0.12), lineWidth: 1)
			}
			.shadow(color: .black.opacity(0.45), radius: 24, y: 12)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.allowsHitTesting(false)
	}

	@ViewBuilder
	private var content: some View {
		if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Art"),
			let image = NSImage(contentsOf: url) {
			Image(nsImage: image).resizable().interpolation(.high)
				.accessibilityHidden(true)
		} else {
			missingMedia
		}
	}

	private var missingMedia: some View {
		ZStack {
			Color(white: 0.12)
			VStack(spacing: 8) {
				Image(systemName: "photo.badge.exclamationmark")
					.font(.system(size: 28, weight: .medium))
					.foregroundStyle(.white.opacity(0.7))
				Text("Preview unavailable")
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(.white.opacity(0.7))
			}
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel("Preview unavailable")
	}
}
