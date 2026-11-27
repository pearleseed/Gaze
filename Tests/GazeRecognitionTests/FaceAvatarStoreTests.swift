import AppKit
import Foundation
import GazeCamera
import GazeRecognition
import Testing

private struct AvatarStoreStubEmbedder: FaceEmbedder {
	let identifier = "avatar-store-stub"
	let usesCosineSimilarity = true
	let matchThreshold: Float = 0.5

	func embed(_ sample: FaceSample) -> Faceprint? { nil }
	func similarity(_ a: Faceprint, _ b: Faceprint) -> Float { 0 }
}

@Suite("Face Avatar Store Persistence")
struct FaceAvatarStoreTests {
	private func makeTempDirectory() throws -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("gaze-avatar-tests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private func makeSampleImage() -> NSImage {
		let image = NSImage(size: NSSize(width: 32, height: 32))
		image.lockFocus()
		NSColor.systemBlue.setFill()
		NSRect(x: 0, y: 0, width: 32, height: 32).fill()
		image.unlockFocus()
		return image
	}

	@MainActor
	private func makeStore(
		portraitsDirectory: URL,
		initialFaces: [FaceEnrollment] = []
	) -> FaceEnrollmentStore {
		var persisted = initialFaces
		return FaceEnrollmentStore(
			baseEmbedder: AvatarStoreStubEmbedder(),
			portraitsDirectory: portraitsDirectory,
			loadVault: { _ in
				guard !persisted.isEmpty else { return nil }
				let data = try JSONEncoder().encode(persisted)
				return try JSONDecoder().decode(StoredFaceEnrollments.self, from: data)
			},
			storeVault: { records, _ in persisted = records },
			removeVault: { _ in persisted = [] },
			authorizeAdd: { true }
		)
	}

	private func makeFace(name: String = "Nam") -> FaceEnrollment {
		FaceEnrollment(
			name: name,
			prints: [Faceprint(values: [1, 0], source: "avatar-store-stub")],
			embedder: "avatar-store-stub",
			cameraID: "cam-1"
		)
	}

	@Test @MainActor func presetPersistsReloadsAndBumpsRevision() throws {
		let dir = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: dir) }

		let face = makeFace()
		let store = makeStore(portraitsDirectory: dir, initialFaces: [face])
		#expect(!store.avatar(for: face.id).isCustomized)

		let initialRevision = store.portraitRevision
		let preset: FaceAvatarPreset = .emoji(symbol: "🦊", color: .amber)
		store.setAvatarPreset(preset, for: face.id)

		#expect(store.portraitRevision == initialRevision &+ 1)
		#expect(store.avatar(for: face.id).preset == preset)
		#expect(store.portrait(for: face.id) == nil)
		#expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(face.id.uuidString).avatar.json").path))

		let reloaded = makeStore(portraitsDirectory: dir, initialFaces: [face])
		#expect(reloaded.avatar(for: face.id).preset == preset)
	}

	@Test @MainActor func monogramNilAndCustomTextPersistAcrossReloads() throws {
		let dir = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: dir) }

		let first = makeFace(name: "Đăng Khoa")
		let second = makeFace(name: "Nam")
		let store = makeStore(portraitsDirectory: dir, initialFaces: [first, second])

		store.setAvatarPreset(.monogram(customText: nil, color: .indigo), for: first.id)
		store.setAvatarPreset(.monogram(customText: "VN", color: .coral), for: second.id)

		let reloaded = makeStore(portraitsDirectory: dir, initialFaces: [first, second])
		#expect(reloaded.avatar(for: first.id).preset == .monogram(customText: nil, color: .indigo))
		#expect(reloaded.avatar(for: second.id).preset == .monogram(customText: "VN", color: .coral))
	}

	@Test @MainActor func photoAndPresetAreMutuallyExclusiveOnDisk() throws {
		let dir = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: dir) }

		let face = makeFace()
		let store = makeStore(portraitsDirectory: dir, initialFaces: [face])
		let pngURL = dir.appendingPathComponent("\(face.id.uuidString).png")
		let jsonURL = dir.appendingPathComponent("\(face.id.uuidString).avatar.json")

		store.setAvatarPreset(.emoji(symbol: "😎", color: .blue), for: face.id)
		#expect(FileManager.default.fileExists(atPath: jsonURL.path))
		#expect(!FileManager.default.fileExists(atPath: pngURL.path))

		// Switching to a custom photo removes the preset file.
		store.setPortrait(makeSampleImage(), for: face.id)
		#expect(FileManager.default.fileExists(atPath: pngURL.path))
		#expect(!FileManager.default.fileExists(atPath: jsonURL.path))
		#expect(store.portrait(for: face.id) != nil)
		#expect(store.avatar(for: face.id).preset == nil)

		// Switching back to a preset removes the photo file.
		store.setAvatarPreset(.monogram(customText: nil, color: .teal), for: face.id)
		#expect(FileManager.default.fileExists(atPath: jsonURL.path))
		#expect(!FileManager.default.fileExists(atPath: pngURL.path))
		#expect(store.portrait(for: face.id) == nil)
		#expect(store.avatar(for: face.id).preset == .monogram(customText: nil, color: .teal))
	}

	@Test @MainActor func clearingDeletesBothFilesAndResetsCache() throws {
		let dir = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: dir) }

		let face = makeFace()
		let store = makeStore(portraitsDirectory: dir, initialFaces: [face])
		let jsonURL = dir.appendingPathComponent("\(face.id.uuidString).avatar.json")

		store.setAvatarPreset(.emoji(symbol: "🚀", color: .purple), for: face.id)
		#expect(FileManager.default.fileExists(atPath: jsonURL.path))

		let beforeClear = store.portraitRevision
		store.setAvatarPreset(nil, for: face.id)
		#expect(store.portraitRevision == beforeClear &+ 1)
		#expect(!FileManager.default.fileExists(atPath: jsonURL.path))
		#expect(!store.avatar(for: face.id).isCustomized)
	}

	@Test @MainActor func corruptOrUnknownPresetJsonFallsBackGracefully() throws {
		let dir = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: dir) }

		let faceTruncated = makeFace(name: "Truncated")
		let faceUnknownColor = makeFace(name: "UnknownColor")
		let faceWithPhotoFallback = makeFace(name: "PhotoFallback")
		let storeSetup = makeStore(
			portraitsDirectory: dir,
			initialFaces: [faceTruncated, faceUnknownColor, faceWithPhotoFallback])
		storeSetup.setPortrait(makeSampleImage(), for: faceWithPhotoFallback.id)

		let truncated = Data("{ \"emoji\": { \"symbol\": \"🦊\"".utf8)
		let unknownColor = Data("{\"emoji\":{\"symbol\":\"🦊\",\"color\":\"neon_green\"}}".utf8)
		try truncated.write(to: dir.appendingPathComponent("\(faceTruncated.id.uuidString).avatar.json"))
		try unknownColor.write(to: dir.appendingPathComponent("\(faceUnknownColor.id.uuidString).avatar.json"))
		try unknownColor.write(to: dir.appendingPathComponent("\(faceWithPhotoFallback.id.uuidString).avatar.json"))

		let reloaded = makeStore(
			portraitsDirectory: dir,
			initialFaces: [faceTruncated, faceUnknownColor, faceWithPhotoFallback])
		#expect(!reloaded.avatar(for: faceTruncated.id).isCustomized)
		#expect(!reloaded.avatar(for: faceUnknownColor.id).isCustomized)
		#expect(reloaded.avatar(for: faceWithPhotoFallback.id).photo != nil)
	}

	@Test @MainActor func invalidPresetWriteIsIgnoredAndLoadedPresetsAreNormalized() throws {
		let dir = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: dir) }

		let facePhoto = makeFace(name: "KeepPhoto")
		let faceBlankMonogram = makeFace(name: "BlankMonogram")
		let faceInvalidEmojiOnDisk = makeFace(name: "InvalidEmoji")
		let store = makeStore(
			portraitsDirectory: dir,
			initialFaces: [facePhoto, faceBlankMonogram, faceInvalidEmojiOnDisk])

		store.setPortrait(makeSampleImage(), for: facePhoto.id)
		let revisionBeforeInvalid = store.portraitRevision
		store.setAvatarPreset(.emoji(symbol: "   ", color: .blue), for: facePhoto.id)
		#expect(store.portraitRevision == revisionBeforeInvalid)
		#expect(store.avatar(for: facePhoto.id).photo != nil)
		#expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(facePhoto.id.uuidString).png").path))
		#expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(facePhoto.id.uuidString).avatar.json").path))

		// Blank customText in monogram JSON normalizes to nil (auto-initials), not a blank circle.
		let blankMonogramData = try JSONEncoder().encode(FaceAvatarPreset.monogram(customText: "   ", color: .blue))
		try blankMonogramData.write(to: dir.appendingPathComponent("\(faceBlankMonogram.id.uuidString).avatar.json"))

		// Non-emoji symbol in emoji JSON falls back cleanly to photo if present.
		store.setPortrait(makeSampleImage(), for: faceInvalidEmojiOnDisk.id)
		let badEmojiData = try JSONEncoder().encode(FaceAvatarPreset.emoji(symbol: "abc", color: .blue))
		try badEmojiData.write(to: dir.appendingPathComponent("\(faceInvalidEmojiOnDisk.id.uuidString).avatar.json"))

		let reloaded = makeStore(
			portraitsDirectory: dir,
			initialFaces: [facePhoto, faceBlankMonogram, faceInvalidEmojiOnDisk])
		#expect(reloaded.avatar(for: faceBlankMonogram.id).preset == .monogram(customText: nil, color: .blue))
		#expect(reloaded.avatar(for: faceInvalidEmojiOnDisk.id).photo != nil)
	}

	@Test @MainActor func simultaneousFilesResolveToValidPresetAndCleanUpOnWrite() throws {
		let dir = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: dir) }

		let face = makeFace()
		let store = makeStore(portraitsDirectory: dir, initialFaces: [face])
		store.setPortrait(makeSampleImage(), for: face.id)

		let preset: FaceAvatarPreset = .emoji(symbol: "🐱", color: .pink)
		let jsonURL = dir.appendingPathComponent("\(face.id.uuidString).avatar.json")
		try JSONEncoder().encode(preset).write(to: jsonURL)

		let reloaded = makeStore(portraitsDirectory: dir, initialFaces: [face])
		#expect(reloaded.avatar(for: face.id).preset == preset)

		reloaded.setPortrait(makeSampleImage(), for: face.id)
		#expect(!FileManager.default.fileExists(atPath: jsonURL.path))
		#expect(reloaded.avatar(for: face.id).photo != nil)
	}

	@Test @MainActor func removeAndRemoveAllDeleteAvatarMetadataFiles() throws {
		let dir = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: dir) }

		let face1 = makeFace(name: "One")
		let face2 = makeFace(name: "Two")
		let face3 = makeFace(name: "Three")
		let store = makeStore(portraitsDirectory: dir, initialFaces: [face1, face2, face3])

		store.setAvatarPreset(.emoji(symbol: "🐼", color: .slate), for: face1.id)
		store.setAvatarPreset(.monogram(customText: nil, color: .blue), for: face2.id)
		store.setPortrait(makeSampleImage(), for: face3.id)

		let json1 = dir.appendingPathComponent("\(face1.id.uuidString).avatar.json")
		let json2 = dir.appendingPathComponent("\(face2.id.uuidString).avatar.json")
		let png3 = dir.appendingPathComponent("\(face3.id.uuidString).png")

		store.remove(face1.id)
		#expect(!FileManager.default.fileExists(atPath: json1.path))
		#expect(FileManager.default.fileExists(atPath: json2.path))

		try store.removeAll()
		#expect(!FileManager.default.fileExists(atPath: json2.path))
		#expect(!FileManager.default.fileExists(atPath: png3.path))
	}
}
