import SwiftUI

struct SettingsSourceBuildSection: View {
	let updates: RepoRevealHelper

	var body: some View {
		if updates.repositoryURL != nil {
			SettingsSection(
				title: "Source build",
				footer: "For source builds, review and rebuild in your trusted checkout."
			) {
				SettingRow(
					title: "Source folder",
					symbol: "folder"
				) {
					Button("Open Source Folder") { updates.revealRepository() }
						.gazeButton()
				}
			}
		}
	}
}
