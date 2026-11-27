import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GazeDesign
import GazeRecognition

/// One enrolled face, as a tile.
///
/// Modelled on the fingerprint tiles in Touch ID & Password: the glyph is the
/// object, the name is under it and editable in savedApp, and removal appears on
/// approach rather than sitting there as a permanent invitation to destroy
/// something.
struct FaceTile: View {

	let face: FaceEnrollment
	/// The avatar somebody chose for this person — a custom photo, a native Emoji/Monogram
	/// preset, or `.initials` for Gaze's neutral fallback.
	var avatar: FaceAvatar
	/// Whether this face can unlock. Reads through to the store so the switch
	/// settles back when enabling is cancelled at the confirmation prompt.
	var isEnabled: Binding<Bool>
	var rename: (String) -> Void
	var setPortrait: (NSImage?) -> Void
	var setAvatarPreset: (FaceAvatarPreset?) -> Void
	var remove: () -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var hovering = false
	@State private var showingAvatarPicker = false
	/// Keep actions in the focus/accessibility tree even before the pointer arrives.
	@FocusState private var portraitFocused: Bool
	@FocusState private var removeFocused: Bool
	/// The name being typed, committed on Return or when focus leaves.
	///
	/// Bound straight through, every keystroke rewrote the vault and re-encrypted
	/// the whole record — and deleting the last character wrote an empty name that
	/// the store then rejected, so the field could not be cleared to retype.
	@State private var draft: String
	@FocusState private var isEditing: Bool

	init(
		face: FaceEnrollment,
		avatar: FaceAvatar,
		isEnabled: Binding<Bool>,
		rename: @escaping (String) -> Void,
		setPortrait: @escaping (NSImage?) -> Void,
		setAvatarPreset: @escaping (FaceAvatarPreset?) -> Void,
		remove: @escaping () -> Void
	) {
		self.face = face
		self.avatar = avatar
		self.isEnabled = isEnabled
		self.rename = rename
		self.setPortrait = setPortrait
		self.setAvatarPreset = setAvatarPreset
		self.remove = remove
		_draft = State(initialValue: face.name)
	}

	var body: some View {
		VStack(spacing: 6) {
			ZStack(alignment: .topTrailing) {
				// A circle with initials in it — the way macOS draws a person.
				//
				// This was a green squircle with the app's own eye glyph in it, and it was
				// wrong twice over.
				//
				// Wrong shape: every savedApp macOS shows a *person* — Users & Groups, the
				// login window, Contacts, Photos' People album — shows a circle. A rounded
				// square is what it uses for apps and files. This row is people.
				//
				// Wrong content, and worse: the glyph was identical on every tile, so a Mac
				// with four enrolled faces showed four indistinguishable green squares and
				// the name underneath did all the work. Initials are what macOS itself falls
				// back to when a person has no picture, and they make the row scannable —
				// which is the entire job of a tile.
				//
				// Wrong colour, too. Green means *recognised* everywhere in this app; a tile
				// that merely carries somebody's name is not a recognition event, and
				// spending the colour here is the same dilution the sidebar tint note warns
				// about. The tile is neutral; the green stays where it means something.
				// A photo or native Emoji/Monogram preset when chosen; initials when not.
				FaceAvatarView(avatar: avatar, faceName: face.name, size: 52)
					.contentShape(.circle)
					.onTapGesture { showingAvatarPicker = true }

			// A camera badge on hover or keyboard focus, because a context menu nobody
			// right-clicks is a feature nobody finds. Bottom-leading so it cannot
			// collide with the remove button in the opposite corner.
			Group {
				Button {
					showingAvatarPicker = true
				} label: {
					Image(systemName: "camera.fill")
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(.white)
						.padding(5)
						.background(Circle().fill(.black.opacity(0.55)))
				}
				.buttonStyle(.plain)
				.help("Choose an avatar or photo for \(face.name)")
				.accessibilityLabel("Choose a photo for \(face.name)")
				.focused($portraitFocused)
				.opacity(controlsVisible ? 1 : 0)
				.allowsHitTesting(controlsVisible)
				.accessibilityHidden(false)
				.offset(x: -30, y: 30)
				.transition(reduceMotion ? .identity : .opacity)
			}

			// On hover *or* keyboard focus: a control that only exists `if hovering`
			// is in no accessibility tree and unreachable by Tab. Pointer visuals
			// are unchanged; focus joins the same reveal condition.
			Group {
				Button(action: remove) {
					Image(systemName: "minus.circle.fill")
						.font(.system(size: 17))
						.symbolRenderingMode(.palette)
						.foregroundStyle(.white, Theme.danger)
				}
				.buttonStyle(.plain)
				.help("Remove \(face.name)")
				.accessibilityLabel("Remove \(face.name)")
				.focused($removeFocused)
				.opacity(controlsVisible ? 1 : 0)
				.allowsHitTesting(controlsVisible)
				.accessibilityHidden(false)
				.offset(x: 7, y: -7)
				.transition(reduceMotion ? .identity : .opacity)
			}
		}
		.popover(isPresented: $showingAvatarPicker, arrowEdge: .bottom) {
			FaceAvatarPicker(
				faceName: face.name,
				currentAvatar: avatar,
				onSelectPreset: { setAvatarPreset($0) },
				onChoosePhoto: {
					showingAvatarPicker = false
					Task { @MainActor in
						choosePortrait()
					}
				},
				onReset: {
					setAvatarPreset(nil)
					showingAvatarPicker = false
				}
			)
		}
		.animation(
			reduceMotion || portraitFocused || removeFocused || isEditing
				? nil : .easeOut(duration: 0.12),
			value: controlsVisible)

			TextField("Name", text: $draft)
				.textFieldStyle(.plain)
				.font(Typography.detail)
				.foregroundStyle(face.isEnabled ? Theme.label : Theme.secondaryLabel)
				.multilineTextAlignment(.center)
				.lineLimit(1)
				.frame(minWidth: 84)
				.focused($isEditing)
				.onSubmit(commit)
				.onExitCommand {
					draft = face.name
					isEditing = false
				}
				.accessibilityLabel("Name for \(face.name)")
				.help(face.name)
				.onChange(of: isEditing) { _, editing in if !editing { commit() } }
				// Someone else's edit — a rename from another window, or the record
				// reloading — should show here rather than being overwritten by a
				// draft the user never touched.
				.onChange(of: face.name) { _, name in if !isEditing { draft = name } }

			if !face.isEnabled {
				Text("Off, can't unlock")
					.font(Typography.detail)
					.foregroundStyle(Theme.secondaryLabel)
					.multilineTextAlignment(.center)
					.lineLimit(2)
					.fixedSize(horizontal: false, vertical: true)
					.frame(minWidth: 84)
			}

			Toggle("Use \(face.name) to unlock", isOn: isEnabled)
				.labelsHidden()
				.accessibilityLabel("Use \(face.name) to unlock")
				.toggleStyle(.switch)
				.controlSize(.small)
				.tint(Theme.accent)
		}
		.contentShape(Rectangle())
		.contextMenu {
			Button("Choose Avatar…") { showingAvatarPicker = true }
			Button("Choose Photo…") { choosePortrait() }
			if avatar.isCustomized {
				Button("Remove Avatar", role: .destructive) { setAvatarPreset(nil) }
			}
		}
		.onHover { hovering = $0 }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Enrolled face, \(face.name)")
		.accessibilityAction(named: Text("Remove \(face.name)"), remove)
		.accessibilityAction(named: Text("Choose a photo for \(face.name)")) {
			showingAvatarPicker = true
		}
	}

	/// When the overlay actions exist at all.
	///
	/// Hover *or* keyboard focus — including focus on the name field, so Tabbing
	/// into the tile reveals the actions Tab will reach next. Pointer behaviour
	/// is exactly as before.
	private var controlsVisible: Bool {
		hovering || isEditing || portraitFocused || removeFocused || showingAvatarPicker
	}

	/// Opens the system picker and hands back what was chosen.
	///
	/// `NSOpenPanel` rather than a drop target or a `PhotosPicker`: this is a Mac, the file
	/// is on disk, and the panel is the thing people already know. Restricted to images so
	/// the panel cannot return something the store then has to reject.
	private func choosePortrait() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.image]
		panel.allowsMultipleSelection = false
		panel.canChooseDirectories = false
		panel.prompt = "Choose"
		panel.message = "Pick a photo for \(face.name)."
		guard panel.runModal() == .OK, let url = panel.url,
			let image = NSImage(contentsOf: url)
		else { return }
		setPortrait(image)
	}

	private func commit() {
		let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		// An empty name is a slip, not an instruction. Put the old one back rather
		// than leaving a tile with no label under it.
		guard !trimmed.isEmpty else {
			draft = face.name
			return
		}
		guard trimmed != face.name else { return }
		rename(trimmed)
	}
}

/// The tile that starts another enrolment.
///
/// In the row with the faces, not off in a corner of the pane: adding one is the
/// same kind of act as removing one, and Touch ID puts its "Add Fingerprint" in
/// exactly this position.
struct AddFaceTile: View {

	var action: () -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			VStack(spacing: 6) {
				// A filled tile that lightens on hover, not a dashed outline.
				//
				// The dashed rectangle is a drop-zone convention borrowed from the web, and
				// it is the one shape on this pane that has no counterpart anywhere in
				// macOS — Photos, Users & Groups and Touch ID all add with a filled well.
				// It also read as a placeholder rather than a control: a dashed box is what
				// an interface draws where something is *missing*, so the tile looked like
				// a gap in the row instead of the way to fill it.
				//
				// Lightening on hover rather than darkening, because a darker chip reads as
				// a hole punched in the surface.
				// A circle, matching the faces it stands beside. A squircle next to a row of
				// round avatars reads as a different kind of thing rather than as the next
				// slot in the same row.
				Circle()
					.fill(Theme.surface.opacity(hovering ? 1.6 : 1))
					.overlay { Circle().strokeBorder(Theme.separator, lineWidth: 1) }
					.frame(width: 52, height: 52)
					.overlay {
						Image(systemName: "plus")
							.font(.system(size: 22, weight: .medium))
							.foregroundStyle(Theme.secondaryLabel)
					}

				Text("Add a Face")
					.font(Typography.detail)
					.foregroundStyle(Theme.secondaryLabel)
					.lineLimit(1)
					.frame(width: 84)
			}
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }

		.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
	}
}
