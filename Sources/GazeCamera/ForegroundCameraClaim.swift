import Observation

/// App Lock claims the camera while scanning: two sessions at once starve one of frames.
@MainActor @Observable package final class ForegroundCameraClaim {
	package static let shared = ForegroundCameraClaim()

	private var claimCount = 0
	package private(set) var appLockIsScanning = false

	package init() {}

	package func beginAppLockScan() {
		claimCount += 1
		appLockIsScanning = claimCount > 0
	}

	package func endAppLockScan() {
		claimCount = max(0, claimCount - 1)
		appLockIsScanning = claimCount > 0
	}
}
