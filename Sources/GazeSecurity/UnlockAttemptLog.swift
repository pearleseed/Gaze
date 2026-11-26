import AppKit
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Observation
import Synchronization
import UniformTypeIdentifiers

/// What one look at the lock screen came to.
package struct UnlockAttempt: Codable, Identifiable, Sendable {
	package enum Result: String, Codable, Sendable {
		case unlocked
		case notRecognised
		case unknownFace
		case spoofRejected
		case openedAnotherWay
		case leftLocked
		/// Old logs only. Reads as openedAnotherWay in the UI.
		case closedWithoutUnlocking
	}

	package enum Reason: String, Codable, Sendable {
		case tooDark
		case tooFar
		case faceTurned
		case noFace
		case differentPerson
		case movementTimedOut
		case photoOrScreen
	}

	package var id: UUID
	package var date: Date
	package var result: Result
	/// Why a look failed. Optional so older logs still decode.
	package var reason: Reason?
	/// Seconds from wake/lock to unlock, for successes.
	package var duration: TimeInterval?
	/// Photo filename inside the attempts directory, when one was kept.
	package var photoFile: String?
	/// Where the time went on a successful unlock, in seconds: camera start, first
	/// recognition, the steady hold and movement, then macOS accepting the password.
	/// Optional so older logs still decode.
	package var steps: Steps?

	/// Best face-match score seen during the look, and the threshold it was
	/// judged against. Diagnostics only; never gates anything.
	/// Optional so older logs still decode.
	package var bestScore: Float?
	package var threshold: Float?
	/// Frames where a face was found, and frames rejected by the quality gate.
	/// Optional so older logs still decode.
	package var framesWithFace: Int?
	package var qualityRejects: Int?
	/// Lockout counter after this look, and attempts left. Diagnostics only.
	/// Optional so older logs still decode.
	package var consecutiveFailures: Int?
	package var attemptsRemaining: Int?
	/// Why the lock ended without Gaze unlocking: display-slept, saver-started
	/// or gave-up. Filed on looks that did not unlock.
	/// Optional so older logs still decode.
	package var endReason: String?

	package init(
		id: UUID,
		date: Date,
		result: Result,
		reason: Reason? = nil,
		duration: TimeInterval? = nil,
		photoFile: String? = nil,
		steps: Steps? = nil,
		bestScore: Float? = nil,
		threshold: Float? = nil,
		framesWithFace: Int? = nil,
		qualityRejects: Int? = nil,
		consecutiveFailures: Int? = nil,
		attemptsRemaining: Int? = nil,
		endReason: String? = nil
	) {
		self.id = id
		self.date = date
		self.result = result
		self.reason = reason
		self.duration = duration
		self.photoFile = photoFile
		self.steps = steps
		self.bestScore = bestScore
		self.threshold = threshold
		self.framesWithFace = framesWithFace
		self.qualityRejects = qualityRejects
		self.consecutiveFailures = consecutiveFailures
		self.attemptsRemaining = attemptsRemaining
		self.endReason = endReason
	}

	package struct Steps: Codable, Equatable, Sendable {
		package var camera: TimeInterval? = nil
		package var recognise: TimeInterval? = nil
		package var check: TimeInterval? = nil
		package var macOS: TimeInterval? = nil
		/// Seconds from the movement prompt appearing to it being completed.
		package var movement: TimeInterval? = nil
		/// The prompt text shown for the movement challenge.
		package var movementPrompt: String? = nil
		/// Per-pass Follow-the-light scores, oldest first. Optional so older logs still decode.
		package var lookPasses: [String]? = nil

		package init(
			camera: TimeInterval? = nil,
			recognise: TimeInterval? = nil,
			check: TimeInterval? = nil,
			macOS: TimeInterval? = nil,
			movement: TimeInterval? = nil,
			movementPrompt: String? = nil,
			lookPasses: [String]? = nil
		) {
			self.camera = camera
			self.recognise = recognise
			self.check = check
			self.macOS = macOS
			self.movement = movement
			self.movementPrompt = movementPrompt
			self.lookPasses = lookPasses
		}
	}
}

/// Serializes all disk I/O for `UnlockAttemptLog` behind a monotonically increasing
/// generation counter so superseded writes never overwrite a `deleteAll()`.
package actor UnlockAttemptStorageActor {

	private let directoryURL: URL
	package private(set) var generation: UInt64 = 0

	package init(directoryURL: URL) {
		self.directoryURL = directoryURL
	}

	package func advanceGeneration(to target: UInt64) {
		if target > generation {
			generation = target
		}
	}

	package func saveRecord(
		attempt: UnlockAttempt,
		jpegData: Data?,
		trimmedFiles: [String],
		snapshot: [UnlockAttempt],
		generation recordGeneration: UInt64,
		isCurrentGeneration: @Sendable (UInt64) -> Bool
	) -> Bool {
		guard recordGeneration == generation, isCurrentGeneration(recordGeneration) else {
			if let file = attempt.photoFile {
				deleteFile(file)
			}
			return false
		}

		var wrotePhoto = false
		if let jpegData, let file = attempt.photoFile {
			let photoURL = directoryURL.appendingPathComponent(file)
			writeProtected(jpegData, to: photoURL)
			// If deleteAll() arrived during the write, remove the superseded file immediately.
			if !isCurrentGeneration(recordGeneration) {
				deleteFile(file)
				return false
			}
			wrotePhoto = true
		}

		guard recordGeneration == generation, isCurrentGeneration(recordGeneration) else {
			if let file = attempt.photoFile {
				deleteFile(file)
			}
			return false
		}

		deletePhotoFiles(trimmedFiles)
		save(snapshot)
		return wrotePhoto
	}

	package func deleteAll(files: [String], generation targetGeneration: UInt64) {
		if targetGeneration > generation {
			generation = targetGeneration
		}
		deletePhotoFiles(files)
		removeAllJPEGFilesInDirectory()
		if targetGeneration == generation {
			save([])
		}
	}

	package func deleteSupersededFile(_ file: String) {
		deleteFile(file)
	}

	package func deletePhotoFiles(_ files: [String]) {
		for file in files {
			deleteFile(file)
		}
	}

	private func deleteFile(_ file: String) {
		try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(file))
	}

	private func removeAllJPEGFilesInDirectory() {
		guard let contents = try? FileManager.default.contentsOfDirectory(
			at: directoryURL,
			includingPropertiesForKeys: nil
		) else { return }
		for url in contents where url.pathExtension.lowercased() == "jpg" {
			try? FileManager.default.removeItem(at: url)
		}
	}

	private func save(_ attempts: [UnlockAttempt]) {
		guard let data = try? JSONEncoder().encode(attempts) else { return }
		writeProtected(data, to: directoryURL.appendingPathComponent("attempts.json"))
	}

	private func writeProtected(_ data: Data, to url: URL) {
		try? FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try? data.write(to: url, options: [.atomic, .completeFileProtection])
	}
}

/// The recent history behind the Settings “Unlock Attempts” section.
///
/// Photos stay on this Mac: they are written with complete file protection next
/// to the log and are never uploaded anywhere.
@Observable
@MainActor
package final class UnlockAttemptLog {

	package static let shared = UnlockAttemptLog()

	/// When a look keeps its photo. Off by default.
	package enum PhotoPolicy: String, CaseIterable, Sendable {
		case off
		case whenNotGaze
		case always

		package var title: String {
			switch self {
			case .off: return "Off"
			case .whenNotGaze: return "When Gaze doesn't unlock"
			case .always: return "Every time"
			}
		}
	}

	private static let photoPolicyKey = "attemptPhotoPolicy"
	private static let capturesPhotosKey = "captureAttemptPhotos"
	private static let maxAttempts = 50
	private static let retentionDays = 30
	private nonisolated static let photoLongSide: CGFloat = 800
	private nonisolated static let photoQuality = 0.8
	private nonisolated static let jpegCIContext = CIContext(options: [.cacheIntermediates: false])

	package private(set) var attempts: [UnlockAttempt] = []
	// Not observed: filling it while a row draws must not make the list draw again.
	@ObservationIgnored private var photoCache: [String: NSImage] = [:]
	@ObservationIgnored private var loadingPhotoTasks: [String: Task<Void, Never>] = [:]
	@ObservationIgnored private let directoryURL: URL
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private let storage: UnlockAttemptStorageActor
	@ObservationIgnored private let encodeJPEG: @Sendable (CVPixelBuffer) -> Data?
	@ObservationIgnored private var generation: UInt64 = 0
	@ObservationIgnored private let latestGeneration = GenerationBox()
	@ObservationIgnored private var pendingTail: Task<Void, Never>?
	@ObservationIgnored private var pendingTailID: UInt64 = 0
	@ObservationIgnored package private(set) var retainedPhotoCountForTesting = 0

	/// When a look keeps its photo. Off until the person asks for it.
	package var photoPolicy: PhotoPolicy {
		didSet { defaults.set(photoPolicy.rawValue, forKey: Self.photoPolicyKey) }
	}

	/// Whether any look keeps a photo.
	package var capturesPhotos: Bool { photoPolicy != .off }

	package init(
		directoryURL: URL? = nil,
		defaults: UserDefaults = .standard,
		encodeJPEG: (@Sendable (CVPixelBuffer) -> Data?)? = nil
	) {
		let resolvedDirectory = directoryURL ?? Self.defaultDirectory()
		try? FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
		self.directoryURL = resolvedDirectory
		self.defaults = defaults
		self.storage = UnlockAttemptStorageActor(directoryURL: resolvedDirectory)
		self.encodeJPEG = encodeJPEG ?? { Self.jpegData(from: $0) }

		if let raw = defaults.string(forKey: Self.photoPolicyKey),
			let saved = PhotoPolicy(rawValue: raw) {
			photoPolicy = saved
		} else if defaults.bool(forKey: Self.capturesPhotosKey) {
			photoPolicy = .whenNotGaze
		} else {
			photoPolicy = .off
		}
		// A tiny JSON read, once, so the section never flashes empty on launch.
		// Everything heavier — photos, writes, pruning — happens off the main actor.
		let listURL = resolvedDirectory.appendingPathComponent("attempts.json")
		let loaded = (try? Data(contentsOf: listURL))
			.flatMap { try? JSONDecoder().decode([UnlockAttempt].self, from: $0) } ?? []
		let cutoff = Date().addingTimeInterval(TimeInterval(-Self.retentionDays * 24 * 60 * 60))
		let kept = loaded.filter { $0.date >= cutoff }.prefix(Self.maxAttempts)
		attempts = Array(kept)
		let stale = loaded.filter { $0.date < cutoff }
		if !stale.isEmpty {
			let files = stale.compactMap(\.photoFile)
			let storage = self.storage
			enqueueStorageWork {
				await storage.deletePhotoFiles(files)
			}
		}
	}

	/// Records one attempt. Never throws, never blocks: the photo conversion and
	/// every write happen off the main actor through `UnlockAttemptStorageActor`.
	/// Safe to call on the unlock path.
	package func record(_ result: UnlockAttempt.Result, duration: TimeInterval? = nil, steps: UnlockAttempt.Steps? = nil,
		photo: CVPixelBuffer? = nil, reason: UnlockAttempt.Reason? = nil,
		bestScore: Float? = nil, threshold: Float? = nil, framesWithFace: Int? = nil,
		qualityRejects: Int? = nil, consecutiveFailures: Int? = nil, attemptsRemaining: Int? = nil,
		endReason: String? = nil) {
		let id = UUID()
		let keepsPhoto = photo != nil
			&& (photoPolicy == .always || (photoPolicy == .whenNotGaze && result != .unlocked))
		// Scores, counters and the end tag are filed on every look that did not
		// unlock. Unlocks keep the record they already had: duration and steps.
		let isUnlock = result == .unlocked
		let attempt = UnlockAttempt(id: id, date: Date(), result: result, reason: reason, duration: duration,
			photoFile: keepsPhoto ? "\(id.uuidString).jpg" : nil, steps: steps,
			bestScore: isUnlock ? nil : bestScore, threshold: isUnlock ? nil : threshold,
			framesWithFace: isUnlock ? nil : framesWithFace, qualityRejects: isUnlock ? nil : qualityRejects,
			consecutiveFailures: isUnlock ? nil : consecutiveFailures,
			attemptsRemaining: isUnlock ? nil : attemptsRemaining,
			endReason: isUnlock ? nil : endReason)
		attempts.insert(attempt, at: 0)
		if result == .unknownFace || result == .spoofRejected {
			IntruderNotice.shared.noteAttempt(at: attempt.date,
				photo: attempt.photoFile.map { directoryURL.appendingPathComponent($0) })
		}
		var trimmedFiles: [String] = []
		while attempts.count > Self.maxAttempts {
			let removed = attempts.removeLast()
			if let file = removed.photoFile {
				trimmedFiles.append(file)
				loadingPhotoTasks.removeValue(forKey: file)?.cancel()
				photoCache.removeValue(forKey: file)
			}
		}
		let snapshot = attempts
		let recordGeneration = generation
		let generationCheck = makeGenerationCheck()

		// Only wrap/retain the pixel buffer when the active policy actually keeps a photo.
		let frame: RetainedFrame? = keepsPhoto ? photo.map(RetainedFrame.init) : nil
		if frame != nil {
			retainedPhotoCountForTesting &+= 1
		}
		let encoder = encodeJPEG
		let encodeTask: Task<Data?, Never>? = frame.map { retained in
			Task.detached(priority: .utility) {
				guard generationCheck(recordGeneration) else { return nil }
				let data = encoder(retained.buffer)
				guard generationCheck(recordGeneration) else { return nil }
				return data
			}
		}

		let filesToTrim = trimmedFiles
		let storage = self.storage
		enqueueStorageWork { [weak self] in
			let jpegData = await encodeTask?.value
			guard generationCheck(recordGeneration) else {
				if let file = attempt.photoFile {
					await storage.deleteSupersededFile(file)
				}
				return
			}
			let wrotePhoto = await storage.saveRecord(
				attempt: attempt,
				jpegData: jpegData,
				trimmedFiles: filesToTrim,
				snapshot: snapshot,
				generation: recordGeneration,
				isCurrentGeneration: generationCheck
			)
			if wrotePhoto {
				await MainActor.run { [weak self] in
					guard let self, self.generation == recordGeneration else { return }
					self.photoRevision &+= 1
				}
			}
		}
	}

	package func deleteAll() {
		generation &+= 1
		let deleteGeneration = generation
		latestGeneration.set(deleteGeneration)

		let files = attempts.compactMap(\.photoFile)
		attempts = []
		for task in loadingPhotoTasks.values {
			task.cancel()
		}
		loadingPhotoTasks.removeAll()
		photoCache = [:]
		photoRevision &+= 1

		let storage = self.storage
		let generationBump = Task.detached(priority: .utility) {
			await storage.advanceGeneration(to: deleteGeneration)
		}
		enqueueStorageWork {
			await generationBump.value
			await storage.deleteAll(files: files, generation: deleteGeneration)
		}
	}

	/// Waits for all queued storage writes, in-flight encodes, and thumbnail loads to finish.
	package func flushForTesting() async {
		while let tail = pendingTail {
			let observedID = pendingTailID
			await tail.value
			if pendingTailID == observedID {
				break
			}
		}
		while !loadingPhotoTasks.isEmpty {
			let active = Array(loadingPhotoTasks.values)
			for task in active {
				await task.value
			}
		}
	}

	/// Safe to call from a view body: pure dictionary lookup with zero synchronous disk I/O.
	package func photo(for attempt: UnlockAttempt) -> NSImage? {
		// Read so a row redraws once its photo lands in the cache.
		_ = photoRevision
		guard let file = attempt.photoFile else { return nil }
		return photoCache[file]
	}

	/// Loads and decodes the attempt thumbnail off the main actor if not already cached or loading.
	package func loadPhotoIfNeeded(for attempt: UnlockAttempt) {
		guard let file = attempt.photoFile else { return }
		guard photoCache[file] == nil, loadingPhotoTasks[file] == nil else { return }
		guard attempts.contains(where: { $0.id == attempt.id && $0.photoFile == file }) else { return }

		let loadGeneration = generation
		let startRevision = photoRevision
		let attemptID = attempt.id
		let url = directoryURL.appendingPathComponent(file)
		let generationCheck = makeGenerationCheck()

		let task = Task { @MainActor [weak self] in
			let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
				guard !Task.isCancelled, generationCheck(loadGeneration) else { return nil }
				return Self.decodeThumbnailCGImage(at: url)
			}.value

			guard let self else { return }
			if self.generation == loadGeneration {
				self.loadingPhotoTasks.removeValue(forKey: file)
			}
			guard !Task.isCancelled,
				self.generation == loadGeneration,
				self.attempts.contains(where: { $0.id == attemptID && $0.photoFile == file })
			else { return }

			guard let cgImage else {
				// If a background JPEG write finished while we were reading disk, try once more.
				if self.photoRevision != startRevision {
					self.loadPhotoIfNeeded(for: attempt)
				}
				return
			}

			self.photoCache[file] = NSImage(
				cgImage: cgImage,
				size: NSSize(width: cgImage.width, height: cgImage.height)
			)
			self.photoRevision &+= 1
		}
		loadingPhotoTasks[file] = task
	}

	/// Bumped when a photo finishes writing or loading into cache.
	package private(set) var photoRevision = 0

	// MARK: - Helpers

	private final class GenerationBox: Sendable {
		private let value = Mutex<UInt64>(0)

		func set(_ newValue: UInt64) {
			value.withLock { $0 = newValue }
		}

		func matches(_ expected: UInt64) -> Bool {
			value.withLock { $0 == expected }
		}
	}

	private func makeGenerationCheck() -> @Sendable (UInt64) -> Bool {
		let box = latestGeneration
		return { expected in
			box.matches(expected)
		}
	}

	private func enqueueStorageWork(_ operation: @escaping @Sendable () async -> Void) {
		let previous = pendingTail
		pendingTailID &+= 1
		pendingTail = Task.detached(priority: .utility) {
			_ = await previous?.value
			await operation()
		}
	}

	/// A frame handed to the background writer.
	/// `@unchecked Sendable` because `CVPixelBuffer` is a CoreVideo CF handle without `Sendable`
	/// conformance; the retained buffer is read-only once passed to `CIImage` in the detached task.
	private struct RetainedFrame: @unchecked Sendable {
		let buffer: CVPixelBuffer

		init(_ buffer: CVPixelBuffer) {
			self.buffer = buffer
		}
	}

	private nonisolated static func defaultDirectory() -> URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return support.appendingPathComponent("Gaze/Attempts", isDirectory: true)
	}

	private nonisolated static func decodeThumbnailCGImage(at url: URL) -> CGImage? {
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
		let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
		return CGImageSourceCreateImageAtIndex(source, 0, options)
	}

	/// JPEG at 0.8 quality, scaled so the long side is at most 800 px.
	private nonisolated static func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
		var image = CIImage(cvPixelBuffer: pixelBuffer)
		let longSide = max(image.extent.width, image.extent.height)
		if longSide > photoLongSide {
			let scale = photoLongSide / longSide
			image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
		}
		guard let cgImage = jpegCIContext.createCGImage(image, from: image.extent) else { return nil }
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
		else { return nil }
		CGImageDestinationAddImage(destination, cgImage,
			[kCGImageDestinationLossyCompressionQuality as String: photoQuality] as CFDictionary)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return data as Data
	}
}
