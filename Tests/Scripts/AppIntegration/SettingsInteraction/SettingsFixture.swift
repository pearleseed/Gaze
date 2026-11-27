import SwiftUI

struct SettingsFixture: View {
	enum Section { case behaviour, updates, sourceBuild }

	let section: Section
	let driver: FixtureDriver
	@State private var loginItem = SettingsLoginItemState()

	var body: some View {
		Form {
			switch section {
			case .behaviour:
				SettingsBehaviourSection(settings: .shared, loginItem: $loginItem)
			case .updates:
				SettingsUpdatesSection(updates: .shared, updater: .shared)
			case .sourceBuild:
				SettingsSourceBuildSection(updates: .shared)
			}
		}
		.formStyle(.grouped)
		.environment(\.nativeSettingsForm, true)
		.frame(width: 668, height: 660)
		.onAppear { driver.refresh = { loginItem.refresh() } }
		.onDisappear { driver.refresh = nil }
	}
}
