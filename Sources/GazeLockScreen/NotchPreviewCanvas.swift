import AppKit
import SwiftUI

package struct NotchPreviewCanvas: View {
	package let model: NotchCapsuleModel
	package var widthAdjust: Double
	package var heightAdjust: Double
	package var wallpaper: NSImage?
	package var background: Color
	/// Where the panel view really sits in the canvas, measured, so its glass crop lines up.
	@State private var panelFrame: CGRect = .zero

	package init(
		model: NotchCapsuleModel,
		widthAdjust: Double = 0,
		heightAdjust: Double = 0,
		wallpaper: NSImage? = nil,
		background: Color = Color(nsColor: .underPageBackgroundColor)
	) {
		self.model = model
		self.widthAdjust = widthAdjust
		self.heightAdjust = heightAdjust
		self.wallpaper = wallpaper
		self.background = background
	}

	private var panelSize: CGSize {
		CGSize(
			width: 278 + widthAdjust,
			height: (model.shape == .island ? 244 : 32 + ConnectedMetrics.dropHeight) + heightAdjust)
	}

	package var body: some View {
		let hasNotch = NSScreen.main.map { NotchMetrics.hasNotch(on: $0) } ?? true
		return GeometryReader { geometry in
			ZStack(alignment: .top) {
				background
				if let wallpaper {
					Image(nsImage: wallpaper)
						.resizable()
						.scaledToFill()
						.frame(width: geometry.size.width, height: geometry.size.height)
						.clipped()
				}
				NotchCapsule(model: model, width: panelSize.width,
					height: panelSize.height,
					notchInset: 32, cutoutWidth: 180, hasNotch: hasNotch)
					.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("notchPreview")) } action: {
						panelFrame = $0
					}
				if hasNotch {
					UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
						.fill(.black)
						.frame(width: 180, height: 32)
				}
			}
			.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
			.clipped()
			.coordinateSpace(.named("notchPreview"))
			// The lock screen draws its glass from the wallpaper (WallpaperGlass); give the
			// preview the same backdrop, cut from the wallpaper shown here, so it matches.
			.task(id: "\(geometry.size)|\(panelFrame)|\(wallpaper.map { ObjectIdentifier($0).hashValue } ?? 0)") {
				model.backdrop = panelFrame.isEmpty ? nil : Self.backdrop(wallpaper, canvas: geometry.size, panel: panelFrame)
			}
		}
	}

	private static func backdrop(_ wallpaper: NSImage?, canvas: CGSize, panel: CGRect) -> GlassBackdrop? {
		guard let wallpaper, let image = wallpaper.cgImage(forProposedRect: nil, context: nil, hints: nil)
		else { return nil }
		return GlassBackdrop.make(from: image, canvas: canvas, rect: panel)
	}
}
