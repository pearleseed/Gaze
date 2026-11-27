import SwiftUI
import GazeDesign
import GazeUpdates

package struct SettingsUpdatesSection: View {
	let updates: RepoRevealHelper
	@Bindable var updater: AppUpdater

	package var body: some View {
		SettingsSection(
			title: "Updates",
			footer: "Updates are cryptographically verified with EdDSA before installation. Your faces and settings stay."
		) {
			SettingRow(
				title: "Version \(updates.currentVersion)",
				detail: statusDetail,
				symbol: "arrow.trianglehead.2.clockwise"
			) {
				if updater.availableUpdateVersion != nil {
					Button("Install Update…") {
						updater.checkForUpdates()
					}
					.gazeButton(.primary)
				} else {
					Button("Check for Updates…") {
						updater.checkForUpdates()
					}
					.gazeButton()
					.disabled(!updater.canCheckForUpdates)
				}
			}

			RowDivider()
			SettingToggle(
				title: "Check automatically",
				detail: "Look for new versions in the background",
				symbol: "clock.arrow.trianglehead.2.counterclockwise.rotate.90",
				isOn: $updater.automaticallyChecksForUpdates
			)

			RowDivider()
			SettingToggle(
				title: "Download automatically",
				detail: "Download verified updates in the background and install on quit",
				symbol: "arrow.down.circle",
				isOn: $updater.automaticallyDownloadsUpdates
			)
			.disabled(!updater.automaticallyChecksForUpdates)
		}
	}

	private var statusDetail: String {
		Self.statusDetail(
			availableVersion: updater.availableUpdateVersion,
			lastChecked: updater.lastUpdateCheckDate
		)
	}

	package static func statusDetail(
		availableVersion: String?,
		lastChecked: Date?,
		now: Date = Date()
	) -> String {
		if let version = availableVersion, !version.isEmpty {
			return "Gaze \(version) is available."
		}
		if let lastChecked {
			return "Last checked \(relativeFormatter.localizedString(for: lastChecked, relativeTo: now))."
		}
		return "Check for new builds signed with Sparkle."
	}

	private static let relativeFormatter: RelativeDateTimeFormatter = {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .full
		return formatter
	}()
}
