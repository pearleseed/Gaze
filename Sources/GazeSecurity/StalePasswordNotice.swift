import Foundation
import UserNotifications

/// Tells the user, once, that the saved password stopped working. Settings says the
/// same, but nobody opens Settings to find out why the lock screen went quiet.
package enum StalePasswordNotice {
	package static func post() {
		guard Bundle.main.bundleURL.pathExtension == "app" else { return }
		Task {
			let center = UNUserNotificationCenter.current()
			guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
			let content = UNMutableNotificationContent()
			content.title = "Your Mac password changed"
			content.body = "Gaze can’t unlock until you save the new one. Open Gaze Settings, then choose Change next to Account password."
			let request = UNNotificationRequest(identifier: "gaze-stale-password", content: content, trigger: nil)
			try? await center.add(request)
		}
	}
}
