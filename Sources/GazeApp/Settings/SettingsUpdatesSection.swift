import AppKit
import SwiftUI
import GazeDesign
import GazeUpdates

struct SettingsUpdatesSection: View {
	let updates: RepoRevealHelper
	let releases: ReleaseUpdateChecker
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		SettingsSection(
			title: "Updates",
			footer: "Gaze installs the update and restarts. Your faces and settings stay."
		) {
			SettingRow(
				title: releaseRowTitle,
				detail: releaseRowDetail,
				symbol: "arrow.trianglehead.2.clockwise"
			) {
				HStack(spacing: 8) {
					switch releases.installer.state {
					// Progress lives in the release card, in place of its Install button.
					case .downloading, .installing:
						EmptyView()
					default:
						// An installable update is installed from the release card below; the
						// row only keeps Download as the fallback when installing failed.
						if isInstallOffered {
							if case .failed = releases.installer.state {
								Button(releaseButtonTitle) { releaseAction() }
									.gazeButton()
									.disabled(releases.state == .checking)
							} else {
								// A newer build may have shipped since this one was found.
								Button(releases.isRechecking ? "Checking…" : "Check Again") {
									Task { await releases.check() }
								}
								.gazeButton()
								.disabled(releases.isRechecking)
							}
						} else {
							Button(releaseButtonTitle) { releaseAction() }
								.gazeButton()
								.disabled(releases.state == .checking)
						}
					}
				}
			}

			if case .available(let release) = releases.state,
				!release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			{
				RowDivider(inset: 0)
				releaseCard(release)
			}
		}
	}

	/// The release as it reads on GitHub: title, summary, one Install button where the
	/// download button would be, then the pictures and notes.
	private func releaseCard(_ release: ReleaseUpdateChecker.Release) -> some View {
		VStack(spacing: 14) {
			VStack(spacing: 4) {
				// The app icon heads the card, as it heads the release on GitHub.
				Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
					.resizable()
					.interpolation(.high)
					.frame(width: 72, height: 72)
					.accessibilityHidden(true)
					.padding(.bottom, 6)
				Text("Gaze \(release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag)")
					.font(.title2.weight(.bold))
					.foregroundStyle(Theme.label)
				if !release.name.isEmpty, release.name != "Gaze \(release.tag.dropFirst())" {
					Text(release.name)
						.font(Typography.detail)
						.foregroundStyle(Theme.secondaryLabel)
				}
			}
			if isInstallOffered {
				ZStack {
					if releases.installer.state.isBusy {
						installProgressBar
							.transition(.opacity.combined(with: .scale(scale: 0.96)))
					} else {
						InstallMorphLabel(isEnabled: canInstall) { releases.install() }
						.transition(.opacity.combined(with: .scale(scale: 0.96)))
					}
				}
				.frame(height: 36)
				.animation(reduceMotion ? nil : .smooth(duration: 0.35), value: releases.installer.state.isBusy)
			}
			ReleaseNotesView(markdown: release.notes)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
				.textSelection(.enabled)
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal, Theme.rowInset)
		.padding(.vertical, 18)
	}

	/// Where the Install button was: a bar with the percentage beside it, then an
	/// indeterminate bar while the new version is checked and swapped in.
	private var installProgressBar: some View {
		HStack(spacing: 10) {
			if case .downloading(let fraction) = releases.installer.state, fraction < 0.99 {
				ProgressView(value: fraction)
					.progressViewStyle(.linear)
					.animation(reduceMotion ? nil : .smooth(duration: 0.25), value: fraction)
				Text("\(Int((fraction * 100).rounded()))%")
					.font(Typography.detail.monospacedDigit())
					.foregroundStyle(Theme.secondaryLabel)
					.frame(width: 40, alignment: .trailing)
					.contentTransition(.numericText())
			} else {
				ProgressView()
					.progressViewStyle(.linear)
				Text("Installing…")
					.font(Typography.detail)
					.foregroundStyle(Theme.secondaryLabel)
					.fixedSize()
			}
		}
		.frame(width: 260)
	}

	private var releaseRowTitle: String {
		"Version \(updates.currentVersion)"
	}

	private var releaseRowDetail: String? {
		switch releases.state {
		case .idle: return "Check GitHub for a new build."
		case .checking: return "Checking GitHub…"
		case .upToDate: return "Gaze is up to date"
		case .available(let release):
			if case .failed(let message) = releases.installer.state { return message }
			// The tag names the build; the release's own title, when it has one
			// worth showing, says what changed.
			let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
			return release.name.isEmpty || release.name == "Gaze \(version)"
				? "Gaze \(version) is available." : "Gaze \(version) is available — \(release.name)"
		// Concise on purpose: the raw HTTP status stays in the log, not on screen.
		case .failed: return "Couldn’t check for updates. Try again."
		}
	}

	private var releaseButtonTitle: String {
		switch releases.state {
		case .available(let release): return release.downloadURL != nil ? "Download" : "View Release"
		case .checking: return "Checking…"
		case .failed: return "Retry"
		default: return "Check for Updates"
		}
	}

	private func releaseAction() {
		if case .available = releases.state {
			releases.openDownload()
		} else {
			Task { await releases.check() }
		}
	}

	private var isInstallOffered: Bool {
		guard case .available(let release) = releases.state else { return false }
		return release.isInstallable
	}

	private var canInstall: Bool {
		switch releases.installer.state {
		case .idle, .failed: return releases.state != .checking
		case .downloading, .installing: return false
		}
	}
}

/// The Install button. "Install" blurs into a download arrow while the pointer is anywhere
/// over the button, like the website's buttons.
private struct InstallMorphLabel: View {
	var isEnabled: Bool
	var action: () -> Void
	@State private var hovered = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		let morphed = hovered && isEnabled && !reduceMotion
		Button(action: action) {
			ZStack {
				Text("Install")
					.font(.system(size: 14, weight: .semibold))
					.opacity(morphed ? 0 : 1)
					.blur(radius: morphed ? 8 : 0)
				Image(systemName: "arrow.down")
					.font(.system(size: 15, weight: .semibold))
					.opacity(morphed ? 1 : 0)
					.blur(radius: morphed ? 0 : 8)
					.accessibilityHidden(true)
			}
			.frame(width: 160, height: 22)
			.animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.34), value: morphed)
		}
		.buttonStyle(.glassProminent)
		.buttonBorderShape(.capsule)
		.tint(.blue)
		.controlSize(.large)
		.disabled(!isEnabled)
		// On the whole button, glass padding included, not just the word.
		.contentShape(Capsule())
		.onHover { hovered = $0 }
		.accessibilityLabel("Install")
	}
}

extension UpdateInstaller.State {
	var isBusy: Bool {
		switch self {
		case .downloading, .installing: return true
		case .idle, .failed: return false
		}
	}
}
