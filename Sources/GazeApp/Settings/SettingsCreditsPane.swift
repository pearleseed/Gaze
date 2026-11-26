import AppKit
import SwiftUI
import GazeDesign

/// The Credits pane: the people whose work this is built on.
///
/// Its own pane rather than a group tucked under About.
///
/// Not ceremony: nearly everything specific about this app came from someone else — the
/// recognition model, and most of what the settings window looks like. A line at the
/// bottom of an About page is not where you put that.
///
/// Split out of `SettingsView` so the settings hotspot stays navigable; renders exactly
/// what `creditsSection` rendered. Static rows only, so it takes no store or updates.
struct SettingsCreditsPane: View {
	var body: some View {
		VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
			// One glyph per row, not the app's name on a capsule.
			//
			// Each of these was a filled button labelled with the app it opens — "Sapphire",
			// "DynamicLake", "Atoll" — which went wrong twice over. The name was already the
			// first word of the row's own subtitle, so the button restated it; and because
			// the three names are different lengths, the three capsules were different
			// widths, leaving a ragged right edge down a group whose rows are otherwise
			// identical in shape. Three mismatched pills is what the eye catches first.
			//
			// They all do the same thing — open a link — so they take the same control, at
			// the same width, and the row's text says which link it is. The name moves to
			// the tooltip and the accessibility label, where a control's purpose belongs.
			// Kept in step with `credits.ts` on the site, which is the list that gets maintained.
			// People without a public page (nautey) get no link rather than an invented one.
			SettingsSection(
				title: "Who helped",
				footer: "One borrowed model, one app that showed the way, "
					+ "and the people who made it better."
			) {
				creditRow(
					name: "Harsh Vardhan Goswami",
					detail: "Gave Gaze an API key for OpenAI's GPT-6 Astra, which powered much of its development",
					symbol: "person.fill",
					link: "https://github.com/theboringhumane", linkName: "Harsh Vardhan Goswami on GitHub",
					app: .init(
						name: "TheBoringNotch", what: "The open-source notch app for Mac.",
						icon: "app-boringnotch", href: "https://github.com/TheBoredTeam/boring.notch"))

				RowDivider()
				// The recognition model is InsightFace's ArcFace. It was credited to Sapphire,
				// which bundles the same model, but the model and its licence are InsightFace's.
				creditRow(
					name: "deepinsight",
					detail: "Made the ArcFace model this app recognises faces with (weights for non-commercial use)",
					symbol: "brain.head.profile",
					link: "https://github.com/deepinsight/insightface", linkName: "InsightFace on GitHub",
					app: nil)

				RowDivider()
				creditRow(
					name: "cshariq",
					detail: "The Core ML build of that model, from Sapphire",
					symbol: "cpu",
					link: "https://github.com/cshariq", linkName: "cshariq on GitHub",
					app: .init(
						name: "Sapphire", what: "The notch, reimagined.",
						icon: "app-sapphire", href: "https://sapphire-app.tech/"))

				RowDivider()
				creditRow(
					name: "Aviorrok",
					detail: "The notch panel and this window both follow its lead",
					symbol: "macbook",
					link: nil, linkName: nil,
					app: .init(
						name: "DynamicLake", what: "Dynamic Island for Mac.",
						icon: "app-dynamiclake", href: "https://dynamiclake.com"))

				RowDivider()
				creditRow(
					name: "Vanilla",
					detail: "Built the anti-spoofing pipeline",
					symbol: "eye.slash.fill",
					link: "https://github.com/howjin", linkName: "Vanilla on GitHub",
					app: nil)

				RowDivider()
				creditRow(
					name: "Unxnown",
					detail: "Helped develop Gaze and set up the Discord",
					symbol: "bubble.left.and.bubble.right.fill",
					link: "https://github.com/UnxnownYT", linkName: "Unxnown on GitHub",
					app: .init(
						name: "WallX", what: nil,
						icon: "app-wallx", href: "https://github.com/UnxnownYT/WallX"))

				RowDivider()
				// Atoll is his, and belongs here — under him, labelled as his app.
				//
				// It was removed from this pane earlier for a good reason and the wrong one.
				// The good reason: Gaze is not built on Atoll, so it cannot be the *credit* —
				// he is credited for ideas and feedback, which is what he actually gave.
				// The wrong one: dropping the app entirely, when the question "who is this
				// person" has an obvious answer that a reader would want.
				creditRow(
					name: "DanFQ",
					detail: "Ideas for the app, and a great deal of feedback on it",
					symbol: "lightbulb.fill",
					link: "https://github.com/danfq", linkName: "DanFQ on GitHub",
					app: .init(
						name: "Atoll", what: nil,
						icon: "app-atoll", href: "https://getatoll.app"))

				RowDivider()
				creditRow(
					name: "nautey",
					// "…on the macOS beta" was in the site's copy and does not survive the trip
					// into a credits row: it reads as a detail about his machine rather than
					// as a thing he did. What he does is find the breakages first.
					detail: "Moderates the Discord, and finds what's broken before anyone else",
					symbol: "checkmark.seal.fill",
					link: nil, linkName: nil,
					app: nil)

				RowDivider()
				creditRow(
					name: "Jonathan Zhou",
					detail: "The Space-to-retry approach, from Glance (MIT)",
					symbol: "keyboard",
					link: "https://github.com/jonnyoo/glance", linkName: "Glance on GitHub",
					app: .init(
						name: "Glance", what: nil,
						icon: "app-glance", href: "https://github.com/jonnyoo/glance"))
			}

			// Plain text, not a group. An empty card with a caption under it is a group that
			// forgot to have any rows.
			//
			// This was headed "And everyone who said what was wrong", over a paragraph
			// listing everything the Discord had criticised — the settings layout, light
			// mode, "what this app should not claim about itself" — ending "most of it was
			// right".
			//
			// Which is the app talking about itself, at length, in the one section that
			// exists to talk about other people. A reader learns nothing about the Discord
			// from it; they learn that the author feels sheepish. Thanks are for the people
			// who gave the feedback, not an inventory of the feedback.
			VStack(alignment: .leading, spacing: 6) {
				Text("And the Discord")
					.font(Typography.groupTitle)
					.foregroundStyle(Theme.label)
				Text(
					"Every screenshot in this app was picked apart by people there before it "
						+ "shipped. Most of what they said was right, and most of it is in here."
				)
				.font(Typography.detail)
				.foregroundStyle(Theme.secondaryLabel)
				.fixedSize(horizontal: false, vertical: true)
			}
			.padding(.horizontal, 4)
		}
	}

	/// Somebody's own picture, or their app's icon, from the bundle.
	///
	/// Nil is a normal answer, not a failure: the row falls back to its glyph, so a checkout
	/// without `Resources/Credits` still builds and still reads correctly. That matches how
	/// the setup card art behaves, and it is why nothing here throws.
	private func creditPortrait(_ name: String) -> NSImage? {
		guard
			let url = Bundle.main.url(
				forResource: name.lowercased(), withExtension: "png", subdirectory: "Credits")
		else { return nil }
		return NSImage(contentsOf: url)
	}

	/// An app one of the credited people made.
	struct CreditApp {
		let name: String
		/// The app's own one-line description, in its author's words — and nil when nobody
		/// has written one.
		///
		/// Optional because `credits.ts` only carries a description for the two apps Gaze is
		/// actually built on. WallX is listed there as something Unxnown made, with a name,
		/// an icon and a link and no words. Inventing a line for it would be writing someone
		/// else's product description for them, which is how this pane got into trouble the
		/// first time.
		let what: String?
		/// Bundled icon, named `app-<something>` so a person's portrait and an app's icon
		/// cannot collide in the same folder.
		let icon: String
		let href: String
	}

	/// One credited person, and their app underneath them if they have one.
	///
	/// The person is the credit; the app is a fact about the person. Flattening the two into
	/// one row — "cshariq — Sapphire — the recognition model…" — made the app read as the
	/// thing being thanked, which is how DanFQ ended up credited as *Atoll* for work he did
	/// himself. Two rows keep the distinction the site's data already draws: a `name` is
	/// always someone, an `app` is always a product.
	///
	/// Indented and quieter than the person above it, because it is a note attached to that
	/// row rather than a sibling of it.
	private func creditRow(
		name: String, detail: String, symbol: String,
		link: String?, linkName: String?, app: CreditApp?
	) -> some View {
		VStack(spacing: 0) {
			SettingRow(title: name, detail: detail, symbol: symbol, portrait: creditPortrait(name)) {
				if let link, let linkName {
					linkGlyph(linkName) { Self.open(link) }
				}
			}

			if let app {
				HStack(spacing: 10) {
					if let icon = creditPortrait(app.icon) {
						Image(nsImage: icon)
							.resizable()
							.interpolation(.high)
							.aspectRatio(contentMode: .fill)
							.frame(width: 20, height: 20)
							.clipShape(.rect(cornerRadius: 5, style: .continuous))
							.accessibilityHidden(true)
					}

					VStack(alignment: .leading, spacing: 0) {
						// Labelled, so the row cannot be misread as a second person.
						Text("\(app.name) — app")
							.font(Typography.detail)
							.foregroundStyle(Theme.label)
						if let what = app.what {
							Text(what)
								.font(Typography.detail)
								.foregroundStyle(Theme.tertiaryLabel)
						}
					}

					Spacer(minLength: 8)
					linkGlyph(app.name) { Self.open(app.href) }
				}
				// Indented past the portrait column above, so it hangs off the person.
				.padding(.leading, Theme.rowInset + 26 + 12)
				.padding(.trailing, Theme.rowInset)
				.padding(.bottom, 11)
			}
		}
	}

	/// The one link control this pane uses, so every row's is the same width.
	private func linkGlyph(_ name: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: "arrow.up.forward")
		}
		.gazeButton(.standard, size: .small)
		.help("Open \(name)")
		.accessibilityLabel("Open \(name)")
	}

	private static func open(_ address: String) {
		guard let url = URL(string: address) else { return }
		NSWorkspace.shared.open(url)
	}
}
