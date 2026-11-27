import Foundation
import Testing
@testable import GazeApp

@Suite("Settings Search Index")
struct SettingsSearchTests {
	private func ids(_ items: [SettingsSearchItem]) -> [String] { items.map(\.id) }

	@Test func indexShapeCoversEveryPaneAndSection() {
		let all = SettingsSearchItem.all
		#expect(!all.isEmpty, "index is nonempty")
		#expect(Set(ids(all)).count == all.count, "ids are unique")
		let panes: Set<String> = ["face", "security", "apps", "general", "notch", "about", "credits"]
		#expect(all.allSatisfy { panes.contains($0.pane) }, "every destination is a real SettingsPane raw value")
		#expect(Set(all.map(\.pane)) == panes, "every pane is reachable from search")
		let sections: Set<String> = [
			"hero", "unlockSection", "movementsSection", "permissionsSection", "securitySection",
			"behaviourSection", "onboardingSection", "updatesSection",
			"appearanceSection", "NotchSettingsSection", "creditsSection", "aboutSection",
			"appLockSection", "appLockListSection", "appLockOptionsSection", "unlockAttemptsSection",
		]
		#expect(all.allSatisfy { sections.contains($0.section) }, "every section is a real detail anchor")
		#expect(all.allSatisfy { !$0.title.isEmpty && !$0.subtitle.isEmpty }, "every item has a title and subtitle")
	}

	@Test func blankAndUnknownQueriesReturnEmpty() {
		#expect(SettingsSearchItem.results(for: "").isEmpty, "blank query returns no results")
		#expect(SettingsSearchItem.results(for: "   \n\t  ").isEmpty, "whitespace-only query returns no results")
		#expect(SettingsSearchItem.results(for: "zxqvkj").isEmpty, "unknown query returns no results")
	}

	@Test func requiredTopicQueriesAndEnrolmentDestination() throws {
		#expect(ids(SettingsSearchItem.results(for: "password")).contains("password"))
		#expect(ids(SettingsSearchItem.results(for: "camera")).contains("camera-permission"))
		#expect(ids(SettingsSearchItem.results(for: "walk away")).contains("walk-away"))
		#expect(ids(SettingsSearchItem.results(for: "theme")).contains("appearance"))
		#expect(ids(SettingsSearchItem.results(for: "dark")).contains("appearance"))
		#expect(ids(SettingsSearchItem.results(for: "backend")).contains("unlock"))
		#expect(ids(SettingsSearchItem.results(for: "touch id")).contains("touch-id"))
		#expect(ids(SettingsSearchItem.results(for: "movement")).contains("movements"))
		#expect(ids(SettingsSearchItem.results(for: "release")).contains("updates"))
		#expect(ids(SettingsSearchItem.results(for: "onboarding")).contains("onboarding"))
		#expect(ids(SettingsSearchItem.results(for: "notch")).contains("notch"))
		#expect(ids(SettingsSearchItem.results(for: "credits")).contains("credits"))

		let faces = SettingsSearchItem.results(for: "enroll")
		#expect(ids(faces).contains("faces"))
		let facesItem = try #require(faces.first(where: { $0.id == "faces" }))
		#expect(facesItem.pane == "face")
		#expect(facesItem.section == "hero")
	}

	@Test func foldsCaseDiacriticsWhitespaceRequiresAllTokensAndPreservesOrder() {
		let all = SettingsSearchItem.all
		#expect(ids(SettingsSearchItem.results(for: "PASSWORD")) == ids(SettingsSearchItem.results(for: "password")))
		#expect(ids(SettingsSearchItem.results(for: "pässword")).contains("password"))
		#expect(ids(SettingsSearchItem.results(for: "PÄSSWORD")).contains("password"))
		#expect(ids(SettingsSearchItem.results(for: "  walk   away  ")).contains("walk-away"))

		// Every token must match (AND, not OR).
		let touchStored = SettingsSearchItem.results(for: "touch stored password")
		#expect(ids(touchStored).contains("touch-id"))
		#expect(!ids(touchStored).contains("password"))
		#expect(!ids(SettingsSearchItem.results(for: "walk away")).contains("unlock"))

		// Stable ordering: results always follow declared order.
		for query in ["a", "e", "password", "camera", "the", "lock", "face"] {
			let order = SettingsSearchItem.results(for: query).compactMap { item in
				all.firstIndex(where: { candidate in candidate.id == item.id })
			}
			#expect(order == order.sorted(), "results for \(query) keep declared order")
		}
		#expect(ids(SettingsSearchItem.results(for: "password")).first == "password")
	}
}
