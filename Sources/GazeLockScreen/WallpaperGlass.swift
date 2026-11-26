import AppKit
import CoreImage
import ImageIO
import SwiftUI

/// The wallpaper behind the panel's window, cut out, for drawing glass by hand.
///
/// System glass and materials sample the compositor, and the panel's window lives in its own
/// lock screen space with nothing behind it there — so `.glassEffect` and `.ultraThinMaterial`
/// came out as an opaque grey slab. The wallpaper the person actually sees is a file on disk,
/// so the glass is drawn from that instead.
package struct GlassBackdrop: Sendable {
	/// Crop covering the whole window plus `margin` on every side, for the lens to pull from.
	package let image: CGImage
	/// Pixels per point, for `Image(decorative:scale:)`.
	package let scale: CGFloat
	/// The crop's size in points, the window's plus `margin` each side.
	package let size: CGSize

	package init(image: CGImage, scale: CGFloat, size: CGSize) {
		self.image = image
		self.scale = scale
		self.size = size
	}

	/// Barely any blur: the glass refracts a sharp picture and frosts it lightly itself.
	package static let blurRadius: CGFloat = 1
	/// Wallpaper beyond the window's edges, in points, that the rim of the lens bends in.
	package static let margin: CGFloat = 32
	/// Coordinate space of the whole panel view, which the crop is cut to match.
	package static let space = "gazeGlassPanel"

	/// The crop for `rect`, in top-left points on a canvas of `canvas` points that the image
	/// fills (aspect-fill, centred: the desktop's default "Fill Screen").
	package static func make(from source: CGImage, canvas: CGSize, rect: CGRect) -> GlassBackdrop? {
		let pixels = CGSize(width: source.width, height: source.height)
		guard canvas.width > 0, canvas.height > 0, rect.width > 0, rect.height > 0 else { return nil }
		// Aspect-fill: the axis with fewer pixels per point decides the scale.
		let k = min(pixels.width / canvas.width, pixels.height / canvas.height)
		let origin = CGPoint(
			x: (pixels.width - canvas.width * k) / 2, y: (pixels.height - canvas.height * k) / 2)
		let padded = rect.insetBy(dx: -margin, dy: -margin)
		let crop = CGRect(
			x: origin.x + padded.minX * k, y: origin.y + padded.minY * k,
			width: padded.width * k, height: padded.height * k
		).integral
		// CIImage is bottom-left; flip the crop rather than the picture.
		let ciCrop = CGRect(
			x: crop.minX, y: pixels.height - crop.maxY, width: crop.width, height: crop.height)
		let blurred = CIImage(cgImage: source)
			.clampedToExtent()
			.applyingGaussianBlur(sigma: Double(blurRadius * k / 2))
			.cropped(to: ciCrop)
		let context = CIContext(options: [.cacheIntermediates: false])
		guard let image = context.createCGImage(blurred, from: ciCrop) else { return nil }
		return GlassBackdrop(image: image, scale: k, size: padded.size)
	}

	package static func loadImage(_ url: URL) -> CGImage? {
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
		return CGImageSourceCreateImageAtIndex(source, 0, nil)
	}
}

/// The panel outline as the glass shader sees it: a rounded box with its own top and bottom
/// radii, inset from the sides. Close enough for the flared notch shape, whose clip still
/// comes from the real `Shape`.
package struct GlassOutline: Sendable {
	package var inset: CGFloat = 0
	package var topRadius: CGFloat
	package var bottomRadius: CGFloat
	/// Flush with the top of the screen: no glass edge there to bend or light.
	package var openTop = false

	package init(inset: CGFloat = 0, topRadius: CGFloat, bottomRadius: CGFloat, openTop: Bool = false) {
		self.inset = inset
		self.topRadius = topRadius
		self.bottomRadius = bottomRadius
		self.openTop = openTop
	}

	package static func rounded(_ radius: CGFloat) -> GlassOutline {
		GlassOutline(topRadius: radius, bottomRadius: radius)
	}

	/// The shader clamps radii to half the short side, so this is a capsule at any size.
	package static let capsule = GlassOutline.rounded(10_000)

	package static func panel(_ shape: NotchPanelShape) -> GlassOutline {
		GlassOutline(
			inset: shape.topRadius, topRadius: 0, bottomRadius: shape.bottomRadius, openTop: true)
	}
}

/// Liquid Glass drawn from a wallpaper crop by a Metal shader (LiquidGlass.metal): the sharp
/// picture behind, magnified slightly, bent and split into colour at the rim like thick
/// glass, lightly frosted, with a specular edge lit from the top left.
package struct WallpaperGlass<S: Shape>: View {
	package let backdrop: GlassBackdrop
	package let shape: S
	package let outline: GlassOutline
	/// Deepens the dimming over a light wallpaper, so white content keeps its contrast.
	package var lightBehind = false

	package init(backdrop: GlassBackdrop, shape: S, outline: GlassOutline, lightBehind: Bool = false) {
		self.backdrop = backdrop
		self.shape = shape
		self.outline = outline
		self.lightBehind = lightBehind
	}

	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.colorSchemeContrast) private var contrast

	package var body: some View {
		GeometryReader { proxy in
			let frame = proxy.frame(in: .named(GlassBackdrop.space))
			let margin = GlassBackdrop.margin
			let size = proxy.size
			// The crop's origin is `margin` above and left of the window's.
			Image(decorative: backdrop.image, scale: backdrop.scale)
				.resizable()
				.saturation(1.0)
				.frame(width: backdrop.size.width, height: backdrop.size.height)
				.offset(x: -frame.minX, y: -frame.minY)
				.frame(
					width: size.width + margin * 2, height: size.height + margin * 2,
					alignment: .topLeading)
				.clipped()
				.layerEffect(
					ShaderLibrary.liquidGlass(
						.float2(size),
						.float(outline.inset),
						.float(outline.topRadius),
						.float(outline.bottomRadius),
						.float(outline.openTop ? 1 : 0),
						.float(margin),
						.float(colorScheme == .dark ? 1 : 0),
						.float(contrast == .increased ? 1 : 0),
						.float(lightBehind ? 1 : 0)),
					maxSampleOffset: CGSize(width: margin, height: margin))
				.frame(width: size.width, height: size.height)
				.clipShape(shape)
				.overlay {
					// Uniform dim over a light wallpaper, where edge shading alone leaves the centre washed out.
					// Kept light: at 0.35 it flattened the panel into the same grey as the bloom above.
					if lightBehind {
						shape.fill(.black.opacity(0.18))
					}
				}
				// Crisp edge over the dim, so the panel keeps a defined outline.
				.overlay {
					shape.stroke(
						LinearGradient(
							colors: [.white.opacity(0.28), .white.opacity(0.08), .white.opacity(0.18)],
							startPoint: .top, endPoint: .bottom),
						lineWidth: 1)
				}
		}
		.allowsHitTesting(false)
	}
}
