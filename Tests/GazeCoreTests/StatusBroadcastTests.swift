import Foundation
import GazeCore
import Testing

@Suite("Status Broadcast", .serialized)
@MainActor
struct StatusBroadcastTests {
	private func emitAllEvents() {
		GazeStatusBroadcast.resetForTesting()
		GazeStatusBroadcast.hello()
		GazeStatusBroadcast.screenLocked()
		GazeStatusBroadcast.scanStarted()
		for movement in GazeStatusBroadcast.Movement.allCases {
			GazeStatusBroadcast.challenge(movement)
		}
		GazeStatusBroadcast.notRecognised()
		GazeStatusBroadcast.spoofRejected()
		for reason in GazeStatusBroadcast.Reason.allCases {
			GazeStatusBroadcast.unavailable(reason)
		}
		GazeStatusBroadcast.recognised()
		GazeStatusBroadcast.postState()
		GazeStatusBroadcast.scanStopped()
		GazeStatusBroadcast.screenUnlocked(by: .gaze)
		GazeStatusBroadcast.appLockShown(bundleID: "com.example.App")
		GazeStatusBroadcast.appLockUnlocked(bundleID: "com.example.App")
		GazeStatusBroadcast.postState()
	}

	@Test func suppressesAllPostsWhileDisabledAndEmitsValidPayloadsWhenEnabled() {
		let originalSend = GazeStatusBroadcast.send
		let originalEnabled = GazeStatusBroadcast.isEnabled
		defer {
			GazeStatusBroadcast.send = originalSend
			GazeStatusBroadcast.isEnabled = originalEnabled
			GazeStatusBroadcast.resetForTesting()
		}

		var posts: [(String, [String: Any])] = []
		var enabled = false
		GazeStatusBroadcast.send = { posts.append(($0, $1)) }
		GazeStatusBroadcast.isEnabled = { enabled }

		emitAllEvents()
		#expect(posts.isEmpty, "nothing posts while disabled")

		enabled = true
		emitAllEvents()

		let names = Set(posts.map(\.0))
		for event in GazeStatusBroadcast.Event.allCases {
			#expect(names.contains(GazeStatusBroadcast.prefix + event.rawValue), "\(event) posted")
		}
		for (name, info) in posts {
			#expect(name.hasPrefix("com.pearleseed.Gaze.status."), "\(name) prefix")
			#expect(Set(info.keys).isSubset(of: GazeStatusBroadcast.allowedKeys), "\(name) keys \(info.keys.sorted())")
			#expect(info["version"] as? Int == 1, "\(name) version")
			#expect(info["timestamp"] is Double, "\(name) timestamp")
			for (key, value) in info where key != "version" && key != "timestamp" {
				#expect(value is String, "\(name).\(key) is a string")
			}
		}

		posts.removeAll()
		GazeStatusBroadcast.notRecognised()
		GazeStatusBroadcast.notRecognised()
		#expect(posts.count == 1, "repeats are dropped")
	}
}
