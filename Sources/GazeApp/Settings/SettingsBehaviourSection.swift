import ServiceManagement
import SwiftUI
import GazeCore
import GazeDesign
import GazeSecurity

struct SettingsBehaviourSection: View {
	@Bindable var settings: Preferences
	@Binding var loginItem: SettingsLoginItemState

	var body: some View {
		SettingsSection(title: "This Mac",
			footer: behaviourFooter,
			info: behaviourFooter) {
			SettingToggle(
				title: "Open at login",
				detail: loginItem.needsApproval ? "Waiting for approval in System Settings." : nil,
				// Grey, like Login Items in System Settings — and because `Theme.faceID` is
				// documented as Gaze identity only. A power button is not Gaze.
				symbol: "power",
				isOn: Binding(
					get: { loginItem.isEnabled || loginItem.needsApproval },
					set: { loginItem.setEnabled($0) }))

			if loginItem.needsApproval || loginItem.error != nil {
				RowDivider()
				SettingRow(
					title: loginItem.error == nil ? "Approval needed" : "Open at login couldn’t be changed",
					detail: loginItem.error,
					symbol: "exclamationmark.circle"
				) {
					Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
						.gazeButton()
				}
			}

			RowDivider()
			SettingToggle(
				title: "Ask for a password before quitting",
				symbol: "lock.fill",
				isOn: $settings.tamperProtection)

			RowDivider()
			SettingToggle(
				title: "Show in menu bar",
				detail: "Open Gaze from Spotlight or Finder when it’s hidden",
				symbol: "menubar.rectangle",
				isOn: $settings.showsMenuBarIcon)
		}
	}

	private var behaviourFooter: String {
		var notes: [String] = []
		if loginItem.needsApproval {
			notes.append("Approve Gaze in System Settings › General › Login Items.")
		}
		notes.append("Gaze only watches for your screen locking while it's running.")
		return notes.joined(separator: " ")
	}
}

@MainActor
struct SettingsLoginItemState {
	private(set) var isEnabled = LoginItem.isEnabled
	private(set) var needsApproval = LoginItem.needsApproval
	private(set) var error: String?
	private var failedRequest: Bool?

	mutating func setEnabled(_ requested: Bool) {
		let succeeded = LoginItem.setEnabled(requested)
		failedRequest = succeeded ? nil : requested
		error = succeeded ? nil : "Couldn’t change Open at login. Review Login Items in System Settings, then try again."
		refresh()
	}

	mutating func refresh() {
		isEnabled = LoginItem.isEnabled
		needsApproval = LoginItem.needsApproval
		if let requested = failedRequest,
			requested == (isEnabled || needsApproval) {
			error = nil
			failedRequest = nil
		}
	}
}
