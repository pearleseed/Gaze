import Foundation
import GazeApp
import Testing

@Suite("Settings Updates Status Copy")
@MainActor
struct SettingsUpdatesSectionTests {
	@Test func statusDetailPrioritizesAvailableVersionThenLastCheckThenDefault() {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		#expect(
			SettingsUpdatesSection.statusDetail(
				availableVersion: "0.2.0",
				lastChecked: now.addingTimeInterval(-3600),
				now: now
			) == "Gaze 0.2.0 is available."
		)
		let recent = SettingsUpdatesSection.statusDetail(
			availableVersion: nil,
			lastChecked: now.addingTimeInterval(-120),
			now: now
		)
		#expect(recent.hasPrefix("Last checked "))
		#expect(
			SettingsUpdatesSection.statusDetail(
				availableVersion: nil,
				lastChecked: nil,
				now: now
			) == "Check for new builds signed with Sparkle."
		)
		#expect(
			SettingsUpdatesSection.statusDetail(
				availableVersion: "",
				lastChecked: nil,
				now: now
			) == "Check for new builds signed with Sparkle."
		)
	}
}
