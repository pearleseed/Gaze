import Foundation
import GazeSecurity
import Testing

@Suite("Admin Prompt Parsing, Refusal & Path Policy")
struct AdminPromptTests {
	private func allowed(_ texts: [String], _ others: [String] = []) -> AdminPromptRules.Title? {
		if case .allowed(let title) = AdminPromptRules.evaluate(staticTexts: texts, otherStrings: others) {
			return title
		}
		return nil
	}

	@Test func titleParsingAndSpoofRejection() {
		#expect(
			AdminPromptRules.parseTitle("Installer wants to make changes.")
				== .init(name: "Installer", action: "wants to make changes")
		)
		#expect(AdminPromptRules.parseTitle("“System Settings” wants to make changes.")?.name == "System Settings")
		#expect(AdminPromptRules.parseTitle("\"Foo App\" wants to make changes.")?.name == "Foo App")
		#expect(
			AdminPromptRules.parseTitle("Installer is trying to install new software.")
				== .init(name: "Installer", action: "is trying to install new software")
		)
		#expect(AdminPromptRules.parseTitle("Installer wants to make changes") == nil)
		#expect(AdminPromptRules.parseTitle("Installer would like to make changes.") == nil)
		#expect(AdminPromptRules.parseTitle(" wants to make changes.") == nil)
		#expect(AdminPromptRules.parseTitle("“Installer” needs to finish setup. Evil wants to make changes.") == nil)
		#expect(AdminPromptRules.parseTitle("Evil is trying to “Installer” setup.") == nil)
	}

	@Test func promptEvaluationAllowsApplePromptsAndRefusesInjections() {
		let password = "Enter your password to allow this."
		#expect(allowed(["Installer wants to make changes.", password, "User Name:", "Password:"])?.name == "Installer")
		#expect(allowed(["Foo is trying to modify settings.", "Touch ID or enter your password to allow this."])?.name == "Foo")
		#expect(allowed(["Evil wants to make changes.", "“Installer” needs to finish setup", password]) == nil)
		#expect(allowed(["Evil wants to make changes.", "Please approve this update.", password]) == nil)
		#expect(allowed(["“Installer” needs to finish setup", "Evil wants to make changes."]) == nil)
		#expect(allowed(["Evil wants to make changes.", password], ["“Installer”"]) == nil)
		#expect(allowed(["“Foo” wants to make changes.", password], ["“Foo”"])?.name == "Foo")
		#expect(allowed(["Script Runner wants to make changes.", password]) == nil)
		#expect(allowed([]) == nil)
	}

	@Test func pathPolicyPermitsInstalledApplicationsAndRefusesUntrustedLocations() {
		let home = "/Users/owen"
		#expect(AdminPromptRules.pathRefusal("/Applications/Foo.app", home: home) == nil)
		#expect(AdminPromptRules.pathRefusal("/Applications/Utilities/Foo.app", home: home) == nil)
		#expect(AdminPromptRules.pathRefusal("/Users/owen/Applications/Foo.app", home: home) == nil)
		#expect(AdminPromptRules.pathRefusal("/Users/owen/Downloads/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.pathRefusal("/tmp/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.pathRefusal("/private/var/folders/x/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.pathRefusal("/Volumes/Foo/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.pathRefusal("/Applications/Foo.dmg/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.pathRefusal("/Applications/../tmp/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.pathRefusal("/private/var/folders/x/AppTranslocation/ABC/d/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.pathRefusal("/Users/other/Applications/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.pathRefusal("/Users/owen/ApplicationsX/Foo.app", home: home) != nil)
		#expect(AdminPromptRules.abbreviated("/Users/owen/Applications/Foo.app", home: home) == "~/Applications/Foo.app")
		#expect(AdminPromptRules.abbreviated("/Applications/Foo.app", home: home) == "/Applications/Foo.app")
	}
}
