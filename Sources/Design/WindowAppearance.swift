import AppKit
import ObjectiveC
import SwiftUI

// MARK: - Glass

/// The window's ground: dark glass at the top, fading toward clear at the bottom.
///
/// The window used to be a vibrancy layer under a flat black scrim, and it looked like a
/// grey slab dropped on the desktop — the wallpaper technically came through, but at one
/// unchanging density, so nothing about it read as glass. What makes the system's own
/// panels look like glass is the *gradient*: dense enough at the top to carry a title,
/// thinning as it falls, so the surface admits it is a sheet with light behind it.
///
/// The same shape the notch capsule already uses, which is the point — the panel that drops
/// out of the notch and the window you configure it from should be made of one material.
struct WindowGlass: View {
	var keepsTitle = false
	/// The Semi Liquid Glass theme: the notch panel's material, on a window.
	var extraTranslucent = false

	/// Black, always, when this is the glass theme.
	///
	/// `Theme.scrim` flips to white in a light appearance, which is right for a window that
	/// is trying to look like the system's own — and wrong here. This gradient *is* the
	/// theme: dark at the top thinning to clear at the foot, the same thing the notch panel
	/// does. Flipped white it came out as a pale slab, which is not the material anyone
	/// picked.
	private func scrim(_ opacity: Double) -> Color {
		extraTranslucent ? .black.opacity(opacity) : Theme.scrim(opacity)
	}

	/// A plain solid ground: graphite in dark, pale grey in light. `VibrantBackground` stays underneath purely
	/// for its title-bar handling; the opaque colour on top of it is what you actually see.
	/// Semi Liquid Glass (`extraTranslucent`) still gets the real material for anyone who
	/// wants it.
	private static let solidGround = Theme.dynamic(
		light: Color(white: 0.95),
		dark: Color(white: 0.145))

	var body: some View {
		ZStack {
			// `.behindWindow` on both paths: the material samples the desktop, which is the
			// only way a window is actually glazed rather than painted.
			//
			// This briefly used `.withinWindow` on the glass theme so the material would
			// frost `WallpaperBackdrop`'s copy of the desktop picture. That did make the
			// wallpaper visible, but it was the wrong wallpaper — an image scaled to the
			// window, sitting still while the real one moved. Sampling the desktop means
			// what shows through is what is behind, in the right place, at the right scale,
			// updating as the window moves.
			VibrantBackground(
				material: extraTranslucent ? .hudWindow : .underWindowBackground,
				hidesTitle: !keepsTitle,
				blending: .behindWindow)

			if extraTranslucent {
				// A fall from top to bottom, not a blackout.
				//
				// These stops used to start at 0.94, which is opaque black in all but name.
				// Stacked on `WallpaperBackdrop`'s own 0.62 and the material between them,
				// the window carried three separate scrims and the wallpaper could not
				// survive them — the glass theme rendered as the same flat slab as the solid
				// one, which is what made picking it feel like it did nothing.
				//
				// `WallpaperBackdrop` is the one that owes us legibility and is already
				// sized for it. This one only has to give the sheet its top-to-bottom
				// gradient, so it starts under half and reaches clear.
				LinearGradient(
					stops: [
						.init(color: scrim(0.22), location: 0),
						.init(color: scrim(0.14), location: 0.32),
						.init(color: scrim(0.05), location: 0.68),
						.init(color: scrim(0), location: 1),
					],
					startPoint: .top,
					endPoint: .bottom)

				// The specular top edge — the highlight that tells the eye it's glass. Only
				// on the glass theme; on a solid window it would be an unexplained sheen.
				VStack(spacing: 0) {
					LinearGradient(
						colors: [.white.opacity(0.22), .clear],
						startPoint: .top, endPoint: .bottom)
						.frame(height: 90)
					Spacer(minLength: 0)
				}
				.blendMode(.plusLighter)
				.opacity(0.5)
			} else {
				Self.solidGround
			}
		}
		.ignoresSafeArea()
	}
}

/// A group's surface: a fill, and nothing else.
///
/// No outline. This carried a hairline `strokeBorder` all the way round, and drawing a line
/// around a group is the single loudest non-native thing this window did — System Settings
/// separates a group from its background by *tone alone*, a slightly lighter fill on a
/// darker ground, and never by an edge. An outlined rounded rectangle is a web card, and
/// four of them stacked down a pane read as a web page however native everything inside
/// them is.
///
/// Losing the edge means the fill has to do the work the edge was doing, which is why
/// `Theme.surface` is no longer almost-transparent — see its own note.
///
/// Flat, too, now that the buttons carry the glass.
///
/// This used to be material plus a lit rim, on the argument that depth is what separates a
/// group from its background. The argument was right and applied to the wrong element: with
/// glass on the containers *and* the controls, everything on screen had depth and none of it
/// meant anything. Aviorrok's point — flat containers, glass controls — puts the depth on
/// the thing you can actually touch.
///
/// One fill and one hairline. The group still reads as a surface because the window behind it
/// is glass and this isn't.
struct GlassSurface: ViewModifier {

	var cornerRadius: CGFloat = Theme.cornerRadius
	/// Slightly brighter for things that sit *on* a group rather than being one.
	var fill: Color = Theme.surface

	private var shape: RoundedRectangle {
		RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
	}

	func body(content: Content) -> some View {
		content
			.background { shape.fill(fill) }
			.clipShape(shape)
	}
}

extension View {
	func glassSurface(cornerRadius: CGFloat = Theme.cornerRadius, fill: Color = Theme.surface)
		-> some View
	{
		modifier(GlassSurface(cornerRadius: cornerRadius, fill: fill))
	}
}

// MARK: - Window background

/// The window's vibrancy layer.
///
/// `NSVisualEffectView` rather than a SwiftUI material: materials inside the content view
/// blur whatever the *window* has behind them, which on an opaque window is nothing. Only
/// a view backing the window itself samples the desktop.
struct VibrantBackground: NSViewRepresentable {
	var material: NSVisualEffectView.Material = .sidebar
	/// Settings draws its own heading, so its title would be a second one. A utility window
	/// like the recognition test has no heading of its own and needs to keep AppKit's.
	var hidesTitle = true
	/// What the material is allowed to sample.
	///
	/// `.behindWindow` frosts the desktop. `.withinWindow` frosts whatever this app drew
	/// underneath it, which is the only one of the two that can see `WallpaperBackdrop`.
	///
	/// This was hardcoded to `.behindWindow`, and that is why the wallpaper every comment
	/// in this file talks about has never once appeared on screen: a `behindWindow` effect
	/// view composites the desktop into its rectangle, so it does not blend with the
	/// SwiftUI view below it in the stack — it replaces it. `WallpaperBackdrop` was being
	/// drawn and then painted over on every frame. What you actually saw was the desktop
	/// behind the window, and over a dark desktop that is a flat grey slab, which is
	/// precisely the "painted rather than glazed" failure this type was written to avoid.
	var blending: NSVisualEffectView.BlendingMode = .behindWindow

	func makeNSView(context: Context) -> NSVisualEffectView {
		let view = TransparentHostView()
		view.hidesTitle = hidesTitle
		view.material = material
		view.blendingMode = blending
		view.state = .active
		return view
	}

	func updateNSView(_ view: NSVisualEffectView, context: Context) {
		view.material = material
		view.blendingMode = blending
	}

	/// Clears the window behind itself, and takes the title bar out of the way.
	///
	/// `behindWindow` blending samples the desktop *through* the window, which it can only
	/// do while the window is not opaque. SwiftUI's `Window` ships opaque with a solid
	/// background, so the material had nothing to sample and rendered as flat grey — the
	/// window looked painted rather than glazed.
	///
	/// `.hiddenTitleBar` alone was not enough either: it hides the *title*, but AppKit still
	/// draws a title bar behind it, which showed as a pale band across the top right of the
	/// window — the one place the glass stopped and a grey slab started. Making it
	/// transparent and letting content run full-height is what closes that seam.
	private final class TransparentHostView: NSVisualEffectView {
		var hidesTitle = true

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard let window else { return }
			window.isOpaque = false
			window.backgroundColor = .clear
			window.titlebarAppearsTransparent = true
			window.styleMask.insert(.fullSizeContentView)
			if hidesTitle { window.titleVisibility = .hidden }
			// Drag anywhere. With no title bar to grab, the window was only movable by a
			// strip the user cannot see.
			window.isMovableByWindowBackground = true
		}
	}
}

/// Lets a `.plain` window become key, so its fields take typing and its buttons draw active.
///
/// `.plain` windows are borderless, and borderless windows refuse key status. Giving the
/// window a title bar instead drew macOS's own glass frame around the card, and adding
/// `.titled` to the live window made SwiftUI rebuild it and broke closing it. So the
/// window keeps its borderless style and its class is swapped for a subclass that
/// answers yes to `canBecomeKey` and `canBecomeMain`.
struct KeyablePlainWindow: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView { HostView() }
	func updateNSView(_ nsView: NSView, context: Context) {}

	private final class HostView: NSView {
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard let window, !window.canBecomeKey else { return }
			KeyablePlainWindow.makeKeyable(window)
			window.makeKey()
		}
	}

	@MainActor
	static func makeKeyable(_ window: NSWindow) {
		let base: AnyClass = type(of: window)
		let name = "GazeKeyable_" + NSStringFromClass(base)
		var subclass: AnyClass? = NSClassFromString(name)
		if subclass == nil, let made = objc_allocateClassPair(base, name, 0) {
			let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
			let imp = imp_implementationWithBlock(yes)
			class_addMethod(made, #selector(getter: NSWindow.canBecomeKey), imp, "c@:")
			class_addMethod(made, #selector(getter: NSWindow.canBecomeMain), imp, "c@:")
			objc_registerClassPair(made)
			subclass = made
		}
		if let subclass { object_setClass(window, subclass) }
	}
}
