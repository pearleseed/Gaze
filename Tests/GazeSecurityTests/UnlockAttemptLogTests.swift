import CoreGraphics
import CoreVideo
import Foundation
import GazeCore
import GazeSecurity
import ImageIO
import Synchronization
import Testing

@Suite("UnlockAttemptLog Serialization & Privacy")
@MainActor
struct UnlockAttemptLogTests {

	private func makeIsolatedContext() -> (directory: URL, defaults: UserDefaults, cleanup: () -> Void) {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("gaze-attempt-log-tests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let suiteName = "com.pearleseed.gaze.tests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return (dir, defaults, {
			try? FileManager.default.removeItem(at: dir)
			defaults.removePersistentDomain(forName: suiteName)
		})
	}

	private func makePixelBuffer(width: Int = 64, height: Int = 64) throws -> CVPixelBuffer {
		var buffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault,
			width,
			height,
			kCVPixelFormatType_32BGRA,
			nil,
			&buffer
		)
		#expect(status == kCVReturnSuccess)
		return try #require(buffer)
	}

	private func jpegFiles(in directory: URL) throws -> [URL] {
		guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
		let contents = try FileManager.default.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil
		)
		return contents.filter { $0.pathExtension.lowercased() == "jpg" }
	}

	private func persistedAttempts(in directory: URL) throws -> [UnlockAttempt] {
		let url = directory.appendingPathComponent("attempts.json")
		let data = try Data(contentsOf: url)
		return try JSONDecoder().decode([UnlockAttempt].self, from: data)
	}

	@Test func rapidRecordsFollowedByImmediateDeleteAllLeavesEmptyLogAndZeroJPEGs() async throws {
		let ctx = makeIsolatedContext()
		defer { ctx.cleanup() }

		let log = UnlockAttemptLog(directoryURL: ctx.directory, defaults: ctx.defaults)
		log.photoPolicy = .always
		let buffer = try makePixelBuffer()

		for _ in 0..<5 {
			log.record(.notRecognised, photo: buffer, reason: .noFace)
		}
		log.deleteAll()

		await log.flushForTesting()

		#expect(log.attempts.isEmpty)
		#expect(try persistedAttempts(in: ctx.directory).isEmpty)
		#expect(try jpegFiles(in: ctx.directory).isEmpty)
	}

	@Test func deleteAllSupersedesInFlightJPEGEncodesBeforeDiskWrite() async throws {
		let ctx = makeIsolatedContext()
		defer { ctx.cleanup() }

		let startedCount = Mutex(0)
		let gate = DispatchSemaphore(value: 0)

		let log = UnlockAttemptLog(
			directoryURL: ctx.directory,
			defaults: ctx.defaults,
			encodeJPEG: { _ in
				startedCount.withLock { $0 += 1 }
				gate.wait()
				return Data([0xFF, 0xD8, 0xFF, 0xD9])
			}
		)
		log.photoPolicy = .always
		let buffer = try makePixelBuffer()

		for _ in 0..<5 {
			log.record(.notRecognised, photo: buffer, reason: .noFace)
		}

		// Give the detached encoder a moment to enter encodeJPEG so at least one encode is truly in-flight.
		let deadline = ContinuousClock.now.advanced(by: .seconds(1))
		while startedCount.withLock({ $0 }) == 0 && ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(5))
		}
		#expect(startedCount.withLock { $0 } >= 1)

		// Delete all while encoding is blocked off-actor, then unblock all encoders.
		log.deleteAll()
		for _ in 0..<5 {
			gate.signal()
		}

		await log.flushForTesting()

		#expect(log.attempts.isEmpty)
		#expect(try persistedAttempts(in: ctx.directory).isEmpty)
		#expect(try jpegFiles(in: ctx.directory).isEmpty)
	}

	@Test func recordAfterDeleteAllPersistsInOrderWithoutBeingWiped() async throws {
		let ctx = makeIsolatedContext()
		defer { ctx.cleanup() }

		let log = UnlockAttemptLog(directoryURL: ctx.directory, defaults: ctx.defaults)
		log.photoPolicy = .always
		let buffer = try makePixelBuffer()

		for _ in 0..<3 {
			log.record(.notRecognised, photo: buffer, reason: .tooDark)
		}
		log.deleteAll()
		log.record(.unknownFace, photo: buffer, reason: .differentPerson)

		await log.flushForTesting()

		#expect(log.attempts.count == 1)
		let saved = try persistedAttempts(in: ctx.directory)
		#expect(saved.count == 1)
		let keptFile = try #require(saved.first?.photoFile)
		let files = try jpegFiles(in: ctx.directory)
		#expect(files.map(\.lastPathComponent) == [keptFile])
	}

	@Test func offPolicyAndWhenNotGazeUnlockedDoNotRetainOrEncodePhoto() async throws {
		let ctx = makeIsolatedContext()
		defer { ctx.cleanup() }

		let encodeCount = Mutex(0)
		let log = UnlockAttemptLog(
			directoryURL: ctx.directory,
			defaults: ctx.defaults,
			encodeJPEG: { _ in
				encodeCount.withLock { $0 += 1 }
				return Data([0xFF, 0xD8, 0xFF, 0xD9])
			}
		)
		let buffer = try makePixelBuffer()

		// 1. Policy .off with photo buffer provided
		log.photoPolicy = .off
		log.record(.notRecognised, photo: buffer, reason: .noFace)
		#expect(log.attempts.first?.photoFile == nil)
		#expect(log.retainedPhotoCountForTesting == 0)

		// 2. Policy .whenNotGaze + .unlocked with photo buffer provided
		log.photoPolicy = .whenNotGaze
		log.record(.unlocked, duration: 0.4, photo: buffer)
		#expect(log.attempts.first?.photoFile == nil)
		#expect(log.retainedPhotoCountForTesting == 0)

		await log.flushForTesting()
		#expect(encodeCount.withLock { $0 } == 0)
		#expect(try jpegFiles(in: ctx.directory).isEmpty)

		// 3. Control: .whenNotGaze + .notRecognised DOES retain & encode
		log.record(.notRecognised, photo: buffer, reason: .tooFar)
		#expect(log.attempts.first?.photoFile != nil)
		#expect(log.retainedPhotoCountForTesting == 1)

		await log.flushForTesting()
		#expect(encodeCount.withLock { $0 } == 1)
		#expect(try jpegFiles(in: ctx.directory).count == 1)
	}

	@Test func asyncThumbnailLoadPopulatesCacheAndDeleteAllDiscardsStaleLoads() async throws {
		let ctx = makeIsolatedContext()
		defer { ctx.cleanup() }

		let writer = UnlockAttemptLog(directoryURL: ctx.directory, defaults: ctx.defaults)
		writer.photoPolicy = .always
		let buffer = try makePixelBuffer(width: 120, height: 90)
		writer.record(.unknownFace, photo: buffer, reason: .differentPerson)
		await writer.flushForTesting()

		let savedAttempt = try #require(writer.attempts.first)
		#expect(savedAttempt.photoFile != nil)

		// Fresh instance starts with empty photoCache and must NOT read synchronously in photo(for:).
		let reader = UnlockAttemptLog(directoryURL: ctx.directory, defaults: ctx.defaults)
		let loadedAttempt = try #require(reader.attempts.first)
		let initialRevision = reader.photoRevision
		#expect(reader.photo(for: loadedAttempt) == nil)

		reader.loadPhotoIfNeeded(for: loadedAttempt)
		await reader.flushForTesting()

		#expect(reader.photoRevision > initialRevision)
		#expect(reader.photo(for: loadedAttempt) != nil)

		// Now test racing loadPhotoIfNeeded with immediate deleteAll().
		let racer = UnlockAttemptLog(directoryURL: ctx.directory, defaults: ctx.defaults)
		let raceAttempt = try #require(racer.attempts.first)
		racer.loadPhotoIfNeeded(for: raceAttempt)
		racer.deleteAll()
		await racer.flushForTesting()

		#expect(racer.attempts.isEmpty)
		#expect(racer.photo(for: raceAttempt) == nil)
	}

	@Test func loadPhotoIfNeededRetriesOnceWhenWriteFinishesDuringInitialLoad() async throws {
		let ctx = makeIsolatedContext()
		defer { ctx.cleanup() }

		let gate = DispatchSemaphore(value: 0)
		let encodeStarted = Mutex(false)

		let log = UnlockAttemptLog(
			directoryURL: ctx.directory,
			defaults: ctx.defaults,
			encodeJPEG: { buffer in
				encodeStarted.withLock { $0 = true }
				gate.wait()
				// Produce a real valid 1x1 JPEG using ImageIO/CoreGraphics.
				var outData: Data?
				if let space = CGColorSpace(name: CGColorSpace.sRGB),
					let cgContext = CGContext(
						data: nil, width: 16, height: 16, bitsPerComponent: 8,
						bytesPerRow: 0, space: space,
						bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
					),
					let image = cgContext.makeImage() {
					let data = NSMutableData()
					if let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) {
						CGImageDestinationAddImage(dest, image, nil)
						if CGImageDestinationFinalize(dest) {
							outData = data as Data
						}
					}
				}
				_ = buffer
				return outData
			}
		)
		log.photoPolicy = .always
		let buffer = try makePixelBuffer()
		log.record(.notRecognised, photo: buffer, reason: .noFace)
		let attempt = try #require(log.attempts.first)

		let deadline = ContinuousClock.now.advanced(by: .seconds(1))
		while !encodeStarted.withLock({ $0 }) && ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(5))
		}

		// Trigger load before the JPEG lands on disk, then let the JPEG write finish.
		log.loadPhotoIfNeeded(for: attempt)
		gate.signal()
		await log.flushForTesting()

		// Even if load started before write completed, or after, either way the retry/flush loads it cleanly.
		log.loadPhotoIfNeeded(for: attempt)
		await log.flushForTesting()
		#expect(log.photo(for: attempt) != nil)
	}
}
