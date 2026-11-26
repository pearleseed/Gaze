import AppKit
import Foundation
import GazeCore
import Observation
import Synchronization
import UserNotifications
import os

/// Checks GitHub Releases for a newer version of Gaze.
///
/// Queries the GitHub Releases API for `pearleseed/Gaze`, selects the host-architecture DMG
/// (falling back to a universal DMG), verifies SHA-256 via GitHub's native asset `digest`
/// or the matching `.sha256` sidecar asset, and degrades cleanly to browser download when no
/// verified SHA-256 is available.
@Observable
@MainActor
package final class ReleaseUpdateChecker {

	package static let shared = ReleaseUpdateChecker()

	private static let logger = Logger(subsystem: AppIdentity.loggerSubsystem, category: "Releases")

	private static let feed = ReleaseURLPolicy.feed

	package struct Release: Equatable, Sendable {
		package let tag: String
		package let name: String
		package let notes: String
		package let downloadURL: URL?
		package let downloadSHA256: String?

		package var isInstallable: Bool {
			downloadURL != nil && downloadSHA256 != nil
		}

		package init(tag: String, name: String, notes: String, downloadURL: URL?, downloadSHA256: String?) {
			self.tag = tag
			self.name = name
			self.notes = notes
			self.downloadURL = downloadURL
			self.downloadSHA256 = downloadSHA256
		}
	}

	package enum State: Equatable, Sendable {
		case idle
		case checking
		case upToDate
		case available(Release)
		/// Reached GitHub and could not make sense of the answer, or could not reach it.
		case failed(String)
	}

	package private(set) var state: State = .idle
	/// A check started while an update is on screen, which leaves it there until a newer
	/// one is found rather than blanking the release card for the length of the request.
	package private(set) var isRechecking = false
	/// Owns the in-app install; the row reads `installer.state` for progress.
	package let installer = UpdateInstaller()
	private let defaults: UserDefaults
	private let sessionConfiguration: () -> URLSessionConfiguration
	private let startupDelay: Duration
	private let hostArchitecture: String
	private let versionOverride: String?

	package static var currentHostArchitecture: String {
		#if arch(arm64)
		return "arm64"
		#elseif arch(x86_64)
		return "x86_64"
		#else
		return "arm64"
		#endif
	}

	package init(
		defaults: UserDefaults = .standard,
		sessionConfiguration: @escaping () -> URLSessionConfiguration = ReleaseURLPolicy.sessionConfiguration,
		startupDelay: Duration = .seconds(8),
		hostArchitecture: String = ReleaseUpdateChecker.currentHostArchitecture,
		currentVersion: String? = nil
	) {
		self.defaults = defaults
		self.sessionConfiguration = sessionConfiguration
		self.startupDelay = startupDelay
		self.hostArchitecture = hostArchitecture
		self.versionOverride = currentVersion
		// The notification delegate cannot reach back through `.shared`: the lifecycle
		// harness forbids that reference file-wide, so each instance registers itself.
		ReleaseNotificationDelegate.shared.setChecker(self)
	}

	/// The version this bundle claims to be.
	package var currentVersion: String {
		versionOverride ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
	}

	// MARK: - Scheduling

	/// When the last successful check finished, so a relaunch doesn't mean a fresh check.
	private static let lastCheckKey = "lastReleaseCheck"

	private var lastCheck: Date? {
		get { defaults.object(forKey: Self.lastCheckKey) as? Date }
		set { defaults.set(newValue, forKey: Self.lastCheckKey) }
	}

	/// The last version a notification was posted for, so each version notifies once.
	private static let lastNotifiedTagKey = "lastNotifiedReleaseTag"

	private var lastNotifiedTag: String? {
		get { defaults.string(forKey: Self.lastNotifiedTagKey) }
		set { defaults.set(newValue, forKey: Self.lastNotifiedTagKey) }
	}

	/// Posts the per-version notification. A closure so tests can observe without delivering.
	/// Nil means post for real; tests set a closure to observe instead.
	@ObservationIgnored package var notificationPoster: (@MainActor (Release) -> Void)?

	/// How often to look, unprompted.
	private static let interval: TimeInterval = 60 * 60 * 24

	/// Never check on a timer more often than this, however often one is triggered.
	private static let minimumInterval: TimeInterval = 60 * 60

	/// Randomised per launch and added to the daily check, so every copy of the app
	/// does not poll GitHub in the same second.
	private static let maximumJitter: TimeInterval = 30 * 60

	private var timer: Timer?

	/// Retried at unlock when a due check was skipped while locked.
	private var unlockObserver: NSObjectProtocol?

	/// Outstanding scheduled work: the deferred post-launch check or a
	/// timer-triggered one. Tracked so stopping the schedule cancels a check
	/// that is still in flight instead of letting it report into a dead schedule.
	private var scheduledWork: Task<Void, Never>?

	/// Bumped every time scheduled work is (re)started or stopped. A finished
	/// task only clears `scheduledWork` when its generation is still current,
	/// so a slow task from before a stop/restart can never nil out newer work.
	private var scheduleGeneration = 0

	/// Starts the background schedule: one check shortly after launch, then daily.
	package func startScheduledChecks() {
		guard timer == nil, scheduledWork == nil else { return }

		scheduleGeneration += 1
		let generation = scheduleGeneration
		let delay = startupDelay
		scheduledWork = Task { [weak self] in
			do {
				try await Task.sleep(for: delay)
			} catch {
				// Stopped before the delay elapsed: never check.
				return
			}
			guard let self else { return }
			guard generation == self.scheduleGeneration else { return }
			guard !Task.isCancelled else { return }
			await self.runScheduledCheck(generation: generation)
		}

		let timer = Timer.scheduledTimer(
			withTimeInterval: Self.interval + Double.random(in: 0...Self.maximumJitter), repeats: true
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.enqueueTimerCheck()
			}
		}
		// Common modes, so it keeps firing while a menu is open.
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer

		// A check skipped while locked is picked up at the next unlock.
		unlockObserver = DistributedNotificationCenter.default().addObserver(
			forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self else { return }
				await self.checkIfDue()
			}
		}
	}

	/// Stops the background schedule and cancels any scheduled check in flight.
	package func stopScheduledChecks() {
		scheduleGeneration += 1
		timer?.invalidate()
		timer = nil
		scheduledWork?.cancel()
		scheduledWork = nil
		if let unlockObserver {
			DistributedNotificationCenter.default().removeObserver(unlockObserver)
			self.unlockObserver = nil
		}
	}

	isolated deinit {
		timer?.invalidate()
		scheduledWork?.cancel()
		if let unlockObserver {
			DistributedNotificationCenter.default().removeObserver(unlockObserver)
		}
	}

	/// Queues one daily-timer check as cancellable scheduled work on this instance.
	private func enqueueTimerCheck() {
		guard timer != nil else { return }
		scheduleGeneration += 1
		let generation = scheduleGeneration
		scheduledWork = Task { [weak self] in
			guard let self else { return }
			await self.runScheduledCheck(generation: generation)
		}
	}

	/// Runs one scheduled due-check, releasing the tracked work unless a
	/// stop/restart (or a newer timer tick) has superseded it meanwhile.
	private func runScheduledCheck(generation: Int) async {
		await checkIfDue()
		if scheduleGeneration == generation { scheduledWork = nil }
	}

	/// Checks only if enough time has passed, and never while offering an update.
	///
	/// Once `available` is on screen, re-checking can only either confirm it or — on a
	/// flaky connection — replace a real answer with "couldn't reach GitHub", turning a
	/// working notification into an error nobody asked for.
	package func checkIfDue() async {
		if case .available = state { return }
		if Self.isLocked() { return }
		if let last = lastCheck {
			let elapsed = Date().timeIntervalSince(last)
			if elapsed >= 0, elapsed < Self.minimumInterval { return }
		}
		await check()
	}

	/// Asked of the window server rather than remembered.
	private static func isLocked() -> Bool {
		guard
			let session = CGSessionCopyCurrentDictionary() as? [String: Any],
			let locked = session["CGSSessionScreenIsLocked"] as? Bool
		else { return false }
		return locked
	}

	// MARK: - Checking

	package func check() async {
		guard state != .checking, !isRechecking else { return }
		// A cancelled check restores this rather than reporting an offline
		// failure: stopping the schedule is not the network being down.
		let previous = state
		let keepsOffer: Bool
		if case .available = previous { keepsOffer = true } else { keepsOffer = false }
		if keepsOffer { isRechecking = true } else { state = .checking }
		var cancelled = false
		defer {
			isRechecking = false
			if cancelled {
				state = previous
			} else if keepsOffer, case .failed = state {
				// Not reaching GitHub says nothing about the update already found.
				state = previous
			} else {
				switch state {
				case .upToDate, .available: lastCheck = Date()
				case .idle, .checking, .failed: break
				}
			}
		}

		do {
			switch try await fetchFeed() {
			case .notFound:
				Self.logger.notice("Checked \(Self.feed.absoluteString, privacy: .public): HTTP 404 — up to date")
				state = .upToDate
				return
			case .failed(let message):
				state = .failed(message)
				return
			case .data(let data):
				guard let payload = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
					state = .failed("Couldn't read the update list.")
					return
				}

				if payload.draft == true || payload.prerelease == true {
					Self.logger.notice(
						"Checked \(Self.feed.absoluteString, privacy: .public): latest \(payload.tagName, privacy: .public) is draft or prerelease — up to date"
					)
					state = .upToDate
					return
				}

				guard let candidate = Version(payload.tagName), let current = Version(currentVersion) else {
					state = .failed("Couldn't read the release version.")
					return
				}
				guard candidate > current else {
					Self.logger.notice(
						"Checked \(Self.feed.absoluteString, privacy: .public): latest \(payload.tagName, privacy: .public), running \(self.currentVersion, privacy: .public) — up to date"
					)
					state = .upToDate
					return
				}

				let assets = payload.assets ?? []
				let dmgAsset = Self.selectDMGAsset(from: assets, hostArchitecture: hostArchitecture)
				let downloadURL = dmgAsset.flatMap { ReleaseURLPolicy.download($0.browserDownloadURL) }
				let downloadSHA256: String?
				if let dmgAsset, downloadURL != nil {
					downloadSHA256 = try await resolveSHA256(for: dmgAsset, in: assets)
				} else {
					downloadSHA256 = nil
				}

				let release = Release(
					tag: payload.tagName,
					name: payload.name ?? "",
					notes: payload.body ?? "",
					downloadURL: downloadURL,
					downloadSHA256: downloadSHA256
				)
				state = .available(release)
				Self.logger.notice("Update available: \(payload.tagName, privacy: .public)")
				// One notification per version, however often the state is re-entered.
				if lastNotifiedTag != release.tag {
					lastNotifiedTag = release.tag
					if let notificationPoster {
						notificationPoster(release)
					} else {
						ReleaseUpdateChecker.postNotification(for: release)
					}
				}
			}
		} catch {
			if Self.isCancellation(error) {
				cancelled = true
				return
			}
			state = .failed("Couldn't reach GitHub.")
		}
	}

	private enum FeedFetchResult {
		case data(Data)
		case notFound
		case failed(String)
	}

	private func fetchFeed() async throws -> FeedFetchResult {
		var request = URLRequest(url: Self.feed)
		request.timeoutInterval = 15
		request.cachePolicy = .reloadRevalidatingCacheData
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
		request.setValue("Gaze/\(currentVersion)", forHTTPHeaderField: "User-Agent")

		let session = URLSession(
			configuration: sessionConfiguration(),
			delegate: ReleaseFeedRedirectPolicy(),
			delegateQueue: nil
		)
		defer { session.invalidateAndCancel() }
		let (bytes, response) = try await session.bytes(for: request)
		try Task.checkCancellation()

		guard let http = response as? HTTPURLResponse, let finalURL = http.url,
			ReleaseURLPolicy.isTrustedFeed(finalURL)
		else {
			let code = (response as? HTTPURLResponse)?.statusCode ?? 0
			Self.logger.error("Release check failed: untrusted response or HTTP \(code, privacy: .public)")
			return .failed("GitHub answered \(code).")
		}
		if http.statusCode == 404 {
			return .notFound
		}
		guard (200..<300).contains(http.statusCode) else {
			Self.logger.error("Release check failed: HTTP \(http.statusCode, privacy: .public)")
			return .failed("GitHub answered \(http.statusCode).")
		}
		guard response.expectedContentLength <= ReleaseURLPolicy.maximumFeedBytes else {
			return .failed("The update list is too large.")
		}
		var data = Data()
		for try await byte in bytes {
			try Task.checkCancellation()
			guard data.count < ReleaseURLPolicy.maximumFeedBytes else {
				return .failed("The update list is too large.")
			}
			data.append(byte)
		}
		try Task.checkCancellation()
		return .data(data)
	}

	private func resolveSHA256(
		for dmgAsset: GitHubRelease.Asset, in assets: [GitHubRelease.Asset]
	) async throws -> String? {
		if let inline = Self.parseAssetDigest(dmgAsset.digest) {
			return inline
		}
		guard let sidecar = assets.first(where: { $0.name == "\(dmgAsset.name).sha256" }),
			let sidecarURL = ReleaseURLPolicy.download(sidecar.browserDownloadURL)
		else {
			return nil
		}

		do {
			var request = URLRequest(url: sidecarURL)
			request.timeoutInterval = 15
			request.cachePolicy = .reloadRevalidatingCacheData
			request.setValue("Gaze/\(currentVersion)", forHTTPHeaderField: "User-Agent")

			let session = URLSession(
				configuration: sessionConfiguration(),
				delegate: ReleaseDownloadRedirectPolicy(),
				delegateQueue: nil
			)
			defer { session.invalidateAndCancel() }
			let (bytes, response) = try await session.bytes(for: request)
			try Task.checkCancellation()

			guard let http = response as? HTTPURLResponse, let finalURL = http.url,
				ReleaseURLPolicy.isTrustedDownloadHop(finalURL),
				(200..<300).contains(http.statusCode),
				response.expectedContentLength <= ReleaseURLPolicy.maximumChecksumBytes
			else {
				return nil
			}
			var data = Data()
			for try await byte in bytes {
				try Task.checkCancellation()
				data.append(byte)
				guard data.count <= ReleaseURLPolicy.maximumChecksumBytes else { return nil }
			}
			try Task.checkCancellation()
			return Self.parseChecksumFile(data, expectedFilename: dmgAsset.name)
		} catch {
			if Self.isCancellation(error) { throw error }
			Self.logger.notice("SHA-256 sidecar unavailable for \(dmgAsset.name, privacy: .public); degrading to browser download")
			return nil
		}
	}

	private static func isCancellation(_ error: any Error) -> Bool {
		error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
	}

	private static func selectDMGAsset(
		from assets: [GitHubRelease.Asset], hostArchitecture: String
	) -> GitHubRelease.Asset? {
		let archSuffix = "-\(hostArchitecture).dmg"
		if let archMatch = assets.first(where: {
			$0.name.hasPrefix("Gaze-") && $0.name.hasSuffix(archSuffix)
		}) {
			return archMatch
		}
		return assets.first(where: {
			$0.name == "Gaze.dmg"
				|| ($0.name.hasPrefix("Gaze-")
					&& $0.name.hasSuffix(".dmg")
					&& !$0.name.hasSuffix("-arm64.dmg")
					&& !$0.name.hasSuffix("-x86_64.dmg"))
		})
	}

	private static func parseAssetDigest(_ digest: String?) -> String? {
		guard let digest else { return nil }
		let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
		let prefix = "sha256:"
		guard trimmed.count == prefix.count + 64,
			trimmed.prefix(prefix.count).lowercased() == prefix
		else { return nil }
		let hex = String(trimmed.dropFirst(prefix.count)).lowercased()
		return isValidSHA256Hex(hex) ? hex : nil
	}

	private static func parseChecksumFile(_ data: Data, expectedFilename: String) -> String? {
		guard data.count <= ReleaseURLPolicy.maximumChecksumBytes,
			let text = String(data: data, encoding: .utf8),
			let firstLine = text.split(whereSeparator: \.isNewline).first
		else { return nil }
		let fields = firstLine.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
		guard let rawHex = fields.first else { return nil }
		let hex = String(rawHex).lowercased()
		guard isValidSHA256Hex(hex) else { return nil }
		if fields.count == 2 {
			var filename = String(fields[1]).trimmingCharacters(in: .whitespaces)
			if filename.hasPrefix("*") { filename.removeFirst() }
			guard filename == expectedFilename else { return nil }
		}
		return hex
	}

	private static func isValidSHA256Hex(_ value: String) -> Bool {
		value.count == 64 && value.utf8.allSatisfy {
			(48...57).contains($0) || (97...102).contains($0)
		}
	}

	/// Installs the available release in place, relaunching when done.
	package func install() {
		guard case .available(let release) = state, let url = release.downloadURL else { return }
		let checker = self
		Task {
			await checker.installer.install(
				url: url, sha256: release.downloadSHA256, expectedVersion: release.tag)
		}
	}

	/// Opens the download in the browser.
	package func openDownload() {
		guard case .available(let release) = state else { return }
		let url = release.downloadURL.flatMap { ReleaseURLPolicy.isTrustedDownload($0) ? $0 : nil }
			?? ReleaseURLPolicy.releases
		NSWorkspace.shared.open(url)
	}

	// MARK: - Notifications

	/// Posts one notification per version. The Install action runs the in-app installer;
	/// clicking the notification opens Settings on the Updates section, falling back to
	/// the same URL as Download only when no verified install is offered.
	private static func postNotification(for release: Release) {
		// UNUserNotificationCenter raises outside an app bundle (test harnesses,
		// command-line runs); there is nobody to notify there anyway.
		guard Bundle.main.bundleURL.pathExtension == "app" else { return }
		let title = "Gaze \(Self.displayVersion(for: release.tag)) is ready"
		let url = release.downloadURL.flatMap { ReleaseURLPolicy.isTrustedDownload($0) ? $0 : nil }
			?? ReleaseURLPolicy.releases
		let urlString = url.absoluteString
		let installable = release.isInstallable
		let tag = release.tag
		Task {
			let center = UNUserNotificationCenter.current()
			center.delegate = ReleaseNotificationDelegate.shared
			let install = UNNotificationAction(
				identifier: ReleaseNotificationDelegate.installActionID, title: "Install", options: .foreground)
			center.setNotificationCategories([
				UNNotificationCategory(
					identifier: ReleaseNotificationDelegate.categoryID, actions: [install],
					intentIdentifiers: [], options: [])
			])
			guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
			let content = UNMutableNotificationContent()
			content.title = title
			content.body = installable
				? "Install it now, or anytime from Settings."
				: "Download it from GitHub, or open Settings."
			if installable {
				content.categoryIdentifier = ReleaseNotificationDelegate.categoryID
			}
			content.userInfo = ["url": urlString, "installable": installable]
			let request = UNNotificationRequest(
				identifier: "gaze-release-\(tag)", content: content, trigger: nil)
			try? await center.add(request)
		}
	}

	/// The tag without a leading v, for display.
	package static func displayVersion(for tag: String) -> String {
		var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
		if value.first == "v" || value.first == "V" { value.removeFirst() }
		return value
	}

	// MARK: - Versions

	/// Whether `candidate` is a later version than `current`.
	///
	/// Semantic-version precedence, also accepting short numeric versions and a v prefix.
	/// Build metadata never changes precedence; malformed versions never offer an update.
	package static func isNewer(_ candidate: String, than current: String) -> Bool {
		guard let candidate = Version(candidate), let current = Version(current) else { return false }
		return candidate > current
	}

	private struct Version: Comparable {
		let core: [String]
		let prerelease: [String]

		init?(_ tag: String) {
			var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
			if value.first == "v" || value.first == "V" { value.removeFirst() }
			let build = value.split(separator: "+", omittingEmptySubsequences: false)
			guard (1...2).contains(build.count) else { return nil }
			if build.count == 2, Self.identifiers(build[1]) == nil { return nil }
			let release = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
			let numbers = release[0].split(separator: ".", omittingEmptySubsequences: false)
			guard (1...3).contains(numbers.count), numbers.allSatisfy({ Self.isNumber($0) && Self.hasNoLeadingZero($0) })
			else { return nil }
			core = numbers.map(String.init) + Array(repeating: "0", count: 3 - numbers.count)
			if release.count == 2 {
				guard let identifiers = Self.identifiers(release[1]),
					identifiers.allSatisfy({ !Self.isNumber($0) || Self.hasNoLeadingZero($0) })
				else { return nil }
				prerelease = identifiers
			} else {
				prerelease = []
			}
		}

		static func < (lhs: Self, rhs: Self) -> Bool {
			for (left, right) in zip(lhs.core, rhs.core) where left != right {
				return numberIsLess(left, than: right)
			}
			if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
				return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
			}
			for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
				switch (isNumber(left), isNumber(right)) {
				case (true, true): return numberIsLess(left, than: right)
				case (true, false): return true
				case (false, true): return false
				case (false, false): return left < right
				}
			}
			return lhs.prerelease.count < rhs.prerelease.count
		}

		private static func identifiers(_ value: Substring) -> [String]? {
			let parts = value.split(separator: ".", omittingEmptySubsequences: false)
			guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
				(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
			} }) else { return nil }
			return parts.map(String.init)
		}

		private static func isNumber(_ value: some StringProtocol) -> Bool {
			!value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
		}

		private static func hasNoLeadingZero(_ value: some StringProtocol) -> Bool {
			value.count == 1 || value.first != "0"
		}

		private static func numberIsLess(_ lhs: String, than rhs: String) -> Bool {
			// Compare decimal strings without overflowing Int on a large version component.
			lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
		}
	}

	// MARK: - Wire format

	private struct GitHubRelease: Decodable {
		let tagName: String
		let name: String?
		let body: String?
		let prerelease: Bool?
		let draft: Bool?
		let assets: [Asset]?

		enum CodingKeys: String, CodingKey {
			case tagName = "tag_name"
			case name
			case body
			case prerelease
			case draft
			case assets
		}

		struct Asset: Decodable {
			let name: String
			let browserDownloadURL: String
			let digest: String?
			let size: Int?

			enum CodingKeys: String, CodingKey {
				case name
				case browserDownloadURL = "browser_download_url"
				case digest
				case size
			}
		}
	}
}

/// Routes the update notification: Install runs the in-app installer, clicking opens
/// Settings on Updates, and only a release with no verified download falls back to the
/// browser. The URL was allow-listed when the notification was posted and is checked
/// again here, so only GitHub opens.
private final class ReleaseNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
	static let shared = ReleaseNotificationDelegate()
	static let categoryID = "gaze-update"
	static let installActionID = "install"

	private struct WeakChecker: Sendable {
		weak var value: ReleaseUpdateChecker?
	}

	/// The checker to install with. A plain reference would need `.shared`, which the
	/// lifecycle harness forbids file-wide, so each checker registers itself in `init`.
	private let checkerBox = Mutex(WeakChecker())

	func setChecker(_ checker: ReleaseUpdateChecker?) {
		checkerBox.withLock { $0.value = checker }
	}

	func userNotificationCenter(
		_ center: UNUserNotificationCenter, willPresent notification: UNNotification
	) async -> UNNotificationPresentationOptions {
		[.banner, .sound]
	}

	func userNotificationCenter(
		_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
	) async {
		let content = response.notification.request.content
		let installable = content.userInfo["installable"] as? Bool == true
		if response.actionIdentifier == Self.installActionID, installable {
			let checker = checkerBox.withLock { $0.value }
			await MainActor.run { checker?.install() }
			return
		}
		guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
		if installable {
			await MainActor.run { SettingsNavigator.shared.openUpdates() }
			return
		}
		guard let value = content.userInfo["url"] as? String,
			let url = URL(string: value), ReleaseURLPolicy.isTrustedBrowserDestination(url)
		else { return }
		_ = await MainActor.run { NSWorkspace.shared.open(url) }
	}
}
