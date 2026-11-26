import SwiftUI

/// Apple's Liquid Glass panel, after the panel recipe in the macOS 27 Figma kit: the
/// system glass as the base, the kit's tint, light bands inside the top and bottom
/// edges, a hairline rim with thin side rims, and the drop shadow.
///
/// Callers pass their own shape so radii stay concentric with what sits inside.
package struct GazeGlassPanel<S: InsettableShape>: ViewModifier {
	package let shape: S
	/// False inside an `NSVisualEffectView`, where glass has nothing of its own to sample.
	package var usesGlass: Bool
	/// False for a panel that is its own borderless window: the window server's shadow
	/// follows the glass already, and a SwiftUI one would be clipped by the window bounds.
	package var castsShadow: Bool

	package init(shape: S, usesGlass: Bool = true, castsShadow: Bool = true) {
		self.shape = shape
		self.usesGlass = usesGlass
		self.castsShadow = castsShadow
	}

	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
	@Environment(\.colorSchemeContrast) private var contrast

	private var isDark: Bool { colorScheme == .dark }

	package func body(content: Content) -> some View {
		content
			.background {
				ZStack {
					if castsShadow { dropShadow }
					base
					if !reduceTransparency { GazeGlassFinish(shape: shape, isDark: isDark) }
				}
				.allowsHitTesting(false)
			}
			.overlay { GazeGlassRims(shape: shape, isDark: isDark, increasedContrast: contrast == .increased) }
	}

	@ViewBuilder
	private var base: some View {
		if reduceTransparency {
			shape.fill(Color(nsColor: .windowBackgroundColor))
		} else if usesGlass {
			Color.clear.glassEffect(.regular, in: shape)
		} else {
			shape.fill(.regularMaterial)
		}
	}

	/// Kit: light y 8 blur 48 black 25%; dark y 8 blur 15 black 2%. Cut out of the
	/// panel's own interior so it never shows through the glass.
	private var dropShadow: some View {
		shape.fill(.black)
			.shadow(color: .black.opacity(isDark ? 0.02 : 0.25), radius: isDark ? 7.5 : 24, y: 8)
			.mask {
				Rectangle().padding(-80)
					.overlay { shape.fill(.black).blendMode(.destinationOut) }
					.compositingGroup()
			}
	}
}

/// The kit's tint and inner-shadow bands, drawn over the glass.
private struct GazeGlassFinish<S: InsettableShape>: View {
	let shape: S
	let isDark: Bool

	var body: some View {
		ZStack {
			if isDark {
				// #101010 plus-lighter + white 4% luminosity: a slight lift.
				shape.fill(.white.opacity(0.06)).blendMode(.plusLighter)
			} else {
				// White 70% lighten + #BFBFBF 10% darken.
				shape.fill(.white.opacity(0.7)).blendMode(.lighten)
				shape.fill(Color(white: 0.75).opacity(0.1)).blendMode(.darken)
			}
			GeometryReader { proxy in
				let height = max(proxy.size.height, 1)
				// Inner shadows spread -40, y ±40, blur 10, #282828 plus-lighter.
				let band = min(10 / height, 0.5)
				shape.fill(LinearGradient(stops: [
					.init(color: .white.opacity(0.16), location: 0),
					.init(color: .clear, location: band),
					.init(color: .clear, location: 1 - band),
					.init(color: .white.opacity(0.16), location: 1),
				], startPoint: .top, endPoint: .bottom))
				.blendMode(.plusLighter)
				if isDark {
					// Inner shadow y +40 blur 30 #E6E6E6 plus-darker: a faint shade along the top.
					let shade = min(30 / height, 0.5)
					shape.fill(LinearGradient(stops: [
						.init(color: Color(white: 0.9), location: 0),
						.init(color: .white, location: shade),
					], startPoint: .top, endPoint: .bottom))
					.blendMode(.plusDarker)
				}
			}
		}
	}
}

/// The kit's 0.5 pt rim outside the shape, plus the two side rims: the outline eroded
/// 0.75 pt and shifted 1.25 pt inward from each side, kept only along that side.
private struct GazeGlassRims<S: InsettableShape>: View {
	let shape: S
	let isDark: Bool
	let increasedContrast: Bool

	var body: some View {
		ZStack {
			if increasedContrast {
				shape.inset(by: -0.5).strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
			} else {
				shape.inset(by: -0.5).strokeBorder(Color(white: isDark ? 0.8 : 0.86), lineWidth: 0.5)
					.blendMode(.plusDarker)
				sideRim(offset: 1.25, from: .leading)
				sideRim(offset: -1.25, from: .trailing)
			}
		}
		.allowsHitTesting(false)
	}

	private func sideRim(offset: CGFloat, from edge: UnitPoint) -> some View {
		shape.inset(by: 0.75).strokeBorder(Color(white: isDark ? 0.82 : 0.86), lineWidth: 0.5)
			.offset(x: offset)
			.blendMode(.plusDarker)
			.mask {
				LinearGradient(colors: [.black, .clear], startPoint: edge, endPoint: .center)
			}
			.clipShape(shape)
	}
}

extension View {
	/// Apple's Liquid Glass panel recipe in `shape`. See `GazeGlassPanel`.
	package func gazeGlassPanel<S: InsettableShape>(in shape: S, usesGlass: Bool = true, castsShadow: Bool = true) -> some View {
		modifier(GazeGlassPanel(shape: shape, usesGlass: usesGlass, castsShadow: castsShadow))
	}

	/// Apple's Liquid Glass panel recipe in a continuous rounded rectangle.
	package func gazeGlassPanel(cornerRadius: CGFloat, usesGlass: Bool = true, castsShadow: Bool = true) -> some View {
		gazeGlassPanel(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
			usesGlass: usesGlass, castsShadow: castsShadow)
	}
}
