import GazeApp
import Testing

@Suite("Settings Updates Card Visibility")
@MainActor
struct SettingsUpdatesSectionTests {
	@Test(arguments: [
		(true, "", true),
		(true, "   \n", true),
		(false, "Fixed bug", true),
		(false, "  ", false),
		(false, "", false),
		(true, "Fixed bug", true),
	])
	func showsReleaseCardCoversInstallableAndNotesCombinations(
		isInstallOffered: Bool,
		notes: String,
		expected: Bool
	) {
		#expect(SettingsUpdatesSection.showsReleaseCard(isInstallOffered: isInstallOffered, notes: notes) == expected)
	}
}
