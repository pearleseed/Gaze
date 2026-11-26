import AppKit
import SwiftUI

/// The About pane: version facts, links out, and the plain-language disclaimer.
///
/// Split out of `SettingsView` so the settings hotspot stays navigable; renders exactly
/// what `aboutSection` rendered. `store` and `updates` are shared reference types, so
/// plain `let`s observe the same instances the settings window holds.
struct SettingsAboutPane: View {
	let store: FaceEnrollmentStore
	let updates: RepoRevealHelper
	@State private var savingDiagnostics = false

	var body: some View {
		VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
			// No second identity block.
			//
			// This pane used to open with a centred glyph, the app's name and its version in
			// a card of its own — directly beneath a header carrying the same glyph and the
			// same name. Two of them stacked, and the card was mostly empty space. The facts
			// are facts; they belong in rows.
			SettingsSection(title: "This app") {
				SettingRow(title: "Version") {
					Text(updates.currentVersion)
						.font(Typography.control)
						.foregroundStyle(Theme.secondaryLabel)
				}
				RowDivider(inset: Theme.rowInset)
				SettingRow(title: "Recognition model") {
					Text("ArcFace, on this Mac")
						.font(Typography.control)
						.foregroundStyle(Theme.secondaryLabel)
				}
				RowDivider(inset: Theme.rowInset)
				SettingRow(title: "Diagnostics", detail: "Saves a report to your Desktop to send when something isn’t working. It never includes your password or photos.") {
					Button(savingDiagnostics ? "Saving…" : "Save Diagnostics") {
						savingDiagnostics = true
						Task {
							if let url = try? await GazeDiagnostics.save() {
								NSWorkspace.shared.activateFileViewerSelecting([url])
							}
							savingDiagnostics = false
						}
					}
					.gazeButton()
					.disabled(savingDiagnostics)
					.fixedSize()
				}
			}

			SettingsSourceBuildSection(updates: updates)

			// Where to go next.
			//
			// This pane had two read-only rows and a paragraph, and every route out of the
			// app — the site, the release notes for the version named directly above, the
			// savedApp to report that something is broken — existed only in a README. An About
			// pane is exactly where somebody looks for those, and "Gaze isn't working" with
			// nowhere in the app to say so is how a bug becomes a person quietly giving up.
			SettingsSection(
				title: "Gaze on the web",
				footer: "Release notes list what changed in each version, including this one."
			) {
				linkRow(
					title: "Website",
					detail: "github.com/\(AppIdentity.repositorySlug)",
					symbol: "safari",
					url: AppIdentity.repositoryURL)
				RowDivider(inset: 0)
				linkRow(
					title: "Release notes",
					detail: "What changed, version by version",
					symbol: "list.bullet.rectangle",
					url: AppIdentity.releasesURL)
				RowDivider(inset: 0)
				linkRow(
					title: "Report a problem",
					detail: "Open an issue on GitHub",
					symbol: "exclamationmark.bubble",
					url: AppIdentity.issuesURL)
			}

			// Said plainly, and said here rather than in a README nobody opens.
			//
			// atmos raised it in the server: the name invites people to assume this is what
			// an iPhone does, and it isn't. The built-in camera has no depth sensor, so the
			// honest version of this app's security claim has to be on its face.
			//
			// Text, not a row with a warning triangle. An orange hazard icon reads as
			// something having gone wrong; this is a permanent, unalarming fact about how the
			// hardware works, and dressing it as an error is its own kind of dishonesty.
			VStack(alignment: .leading, spacing: 6) {
				// Headed by what this *is*, not by whose trademark it is not.
				//
				// It read "Not Apple's Face ID", which made a registered mark the largest
				// words in the pane and defined the app by a comparison to something it was
				// never trying to be. Leading with the plain description is both more useful
				// to a reader and a smaller target: the honest sentence is "a facial
				// recognition app for Mac", and the Face ID paragraph stays because the
				// difference is worth knowing — as the second thing said, not the first.
				Text("What this is")
					.font(Typography.groupTitle)
					.foregroundStyle(Theme.label)
				Text(
					"Gaze is a facial recognition app for Mac. It matches the face at your "
						+ "built-in camera against the one you enrolled, and types your login "
						+ "password when they agree."
				)
				.font(Typography.detail)
				.foregroundStyle(Theme.secondaryLabel)
				.fixedSize(horizontal: false, vertical: true)

				Text(
					"It is not Apple's Face ID, and not connected to Apple. Face ID uses a "
						+ "TrueDepth camera that measures the shape of your face with infrared "
						+ "dots; Macs have no such sensor. Gaze sees a flat image from an "
						+ "ordinary camera, so it cannot tell a face from a good photograph of "
						+ "one the way an iPhone can."
				)
				.font(Typography.detail)
				.foregroundStyle(Theme.secondaryLabel)
				.fixedSize(horizontal: false, vertical: true)
			}
			.padding(.horizontal, 4)

		}
	}

	/// A row whose whole job is to open a link.
	///
	/// Same shape as the credits rows: one glyph button per row rather than the destination's
	/// name on a capsule, so three of them stack without three different widths.
	private func linkRow(
		title: String, detail: String, symbol: String, url: URL
	) -> some View {
		SettingRow(title: title, detail: detail, symbol: symbol) {
			Button {
				NSWorkspace.shared.open(url)
			} label: {
				Image(systemName: "arrow.up.forward")
			}
			.gazeButton(.standard, size: .small)
			.help("Open \(title)")
			.accessibilityLabel("Open \(title)")
		}
	}
}
