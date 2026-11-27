import CoreGraphics
import CoreVideo
import Foundation
import GazeCamera
import GazeCore
import GazeRecognition
import Testing
import Vision

private struct StorageFixtureEmbedder: FaceEmbedder {
	let identifier = "fixture-embedder-v1"
	let usesCosineSimilarity = false
	let matchThreshold: Float = 0.5

	func embed(_ sample: FaceSample) -> Faceprint? {
		Faceprint(values: [1, 0], source: identifier)
	}

	/// Real cosine so `learn` can tell a new angle of the same face from a near-duplicate.
	func similarity(_ a: Faceprint, _ b: Faceprint) -> Float {
		guard a.source == b.source, a.values.count == b.values.count, !a.values.isEmpty else { return 0 }
		var dot: Float = 0, aa: Float = 0, bb: Float = 0
		for i in a.values.indices {
			dot += a.values[i] * b.values[i]
			aa += a.values[i] * a.values[i]
			bb += b.values[i] * b.values[i]
		}
		guard aa > 0, bb > 0, dot.isFinite else { return 0 }
		return dot / (sqrt(aa) * sqrt(bb))
	}
}

private final class InMemoryEnrollmentVault {
	struct SimulatedFailure: Error {}

	var plaintext: Data?
	var loadError: Error?
	var storeError: Error?
	var loadCount = 0
	var storeCount = 0
	var storedPlaintext: Data?

	init(plaintext: Data? = nil) {
		self.plaintext = plaintext
	}

	func load(_ account: String) throws -> StoredFaceEnrollments? {
		loadCount += 1
		if let loadError { throw loadError }
		guard let plaintext else { return nil }
		return try JSONDecoder().decode(StoredFaceEnrollments.self, from: plaintext)
	}

	func store(_ faces: [FaceEnrollment], _ account: String) throws {
		storeCount += 1
		if let storeError { throw storeError }
		storedPlaintext = try JSONEncoder().encode(faces)
	}

	func remove(_ account: String) throws {
		plaintext = nil
		storedPlaintext = nil
	}
}

@Suite("Enrollment Storage & Learning")
@MainActor
struct EnrollmentStorageTests {
	private func makeIsolatedStore(
		vault: InMemoryEnrollmentVault
	) -> (store: FaceEnrollmentStore, cleanup: () -> Void) {
		let suiteName = "com.pearleseed.gaze.enrollmentStorageTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		let preferences = Preferences(defaults: defaults)
		let store = FaceEnrollmentStore(
			baseEmbedder: StorageFixtureEmbedder(),
			preferences: preferences,
			defaults: defaults,
			learnInterval: 0,
			loadVault: vault.load,
			storeVault: vault.store,
			removeVault: vault.remove,
			authorizeAdd: { true }
		)
		return (store, { defaults.removePersistentDomain(forName: suiteName) })
	}

	private nonisolated static func buildUsableSample() throws -> FaceSample {
		var pixelBuffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
		)
		#expect(status == kCVReturnSuccess)
		let buffer = try #require(pixelBuffer)
		let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
		let face = VNFaceObservation(boundingBox: box)
		let request = VNDetectFaceLandmarksRequest()
		request.inputFaceObservations = [face]
		try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
		let landmarks = try #require(request.results?.first?.landmarks)
		return FaceSample(
			landmarks: landmarks,
			boundingBox: box,
			pose: .zero,
			quality: 0.8,
			hasQualityMeasurement: true,
			pixelBuffer: buffer
		)
	}

	private func makeUsableSample() async throws -> FaceSample {
		try await Task.detached(priority: .userInitiated) {
			try Self.buildUsableSample()
		}.value
	}

	private func makeRecord(embedder: String = "fixture-embedder-v1", name: String = "Face") -> FaceEnrollment {
		FaceEnrollment(
			name: name,
			prints: [Faceprint(values: [1, 0], source: embedder)],
			embedder: embedder,
			cameraID: "camera-1"
		)
	}

	private func fp(_ values: [Float]) -> Faceprint {
		Faceprint(values: values, source: "fixture-embedder-v1")
	}

	private func learnedCandidate(_ index: Int, source: String = "fixture-embedder-v1") -> Faceprint {
		var values = [Float](repeating: 0, count: 12)
		values[0] = 0.6
		values[index % 11 + 1] = 0.8
		return Faceprint(values: values, source: source)
	}

	private func learnedBase(source: String = "fixture-embedder-v1") -> Faceprint {
		var values = [Float](repeating: 0, count: 12)
		values[0] = 1
		return Faceprint(values: values, source: source)
	}

	@Test func startupShapesAndSingleReadMigration() throws {
		// Absent enrollment: empty faces, no corruption, exactly one vault read.
		let absentVault = InMemoryEnrollmentVault()
		let (absentStore, absentCleanup) = makeIsolatedStore(vault: absentVault)
		defer { absentCleanup() }
		#expect(absentStore.faces.isEmpty, "Absent enrollment yields no faces")
		#expect(!absentStore.isCorrupted, "Absent enrollment is not corruption")
		#expect(absentVault.loadCount == 1, "Absent enrollment costs exactly one vault load")
		#expect(absentVault.storeCount == 0, "Absent enrollment never rewrites the vault")

		// Valid array: decoded as-is, no vault rewrite, exactly one vault read.
		let pair = [makeRecord(name: "A"), makeRecord(name: "B")]
		let validVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode(pair))
		let (validStore, validCleanup) = makeIsolatedStore(vault: validVault)
		defer { validCleanup() }
		#expect(validStore.faces.count == 2, "Valid array decodes both faces")
		#expect(!validStore.isCorrupted, "Valid array is not corruption")
		#expect(validVault.loadCount == 1, "Valid array costs exactly one vault load")
		#expect(validVault.storeCount == 0, "Valid array never rewrites the vault")

		// Legacy single record: adopted, migrated to the list shape, one vault read.
		let legacy = makeRecord(name: "Legacy")
		let legacyVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode(legacy))
		let (legacyStore, legacyCleanup) = makeIsolatedStore(vault: legacyVault)
		defer { legacyCleanup() }
		#expect(legacyStore.faces.count == 1 && legacyStore.faces[0].name == "Legacy", "Legacy single record is adopted")
		#expect(!legacyStore.isCorrupted, "Legacy single record is not corruption")
		#expect(legacyVault.loadCount == 1, "Legacy single record costs exactly one vault load")
		#expect(legacyVault.storeCount == 1, "Legacy single record triggers one migration write")
		let migratedData = try #require(legacyVault.storedPlaintext)
		let migrated = try JSONDecoder().decode([FaceEnrollment].self, from: migratedData)
		#expect(migrated.count == 1 && migrated[0].name == "Legacy", "Migration persists the legacy face as a list")

		// Malformed JSON: corruption is marked, faces stay empty, one vault read.
		let malformedVault = InMemoryEnrollmentVault(plaintext: Data("not-json".utf8))
		let (malformedStore, malformedCleanup) = makeIsolatedStore(vault: malformedVault)
		defer { malformedCleanup() }
		#expect(malformedStore.faces.isEmpty, "Malformed JSON yields no faces")
		#expect(malformedStore.isCorrupted, "Malformed JSON marks corruption")
		#expect(malformedVault.loadCount == 1, "Malformed JSON costs exactly one vault load")

		// Simulated vault failure: corruption, never mistaken for absence, one read.
		let failingVault = InMemoryEnrollmentVault()
		failingVault.loadError = InMemoryEnrollmentVault.SimulatedFailure()
		let (failingStore, failingCleanup) = makeIsolatedStore(vault: failingVault)
		defer { failingCleanup() }
		#expect(failingStore.faces.isEmpty, "Vault failure yields no faces")
		#expect(failingStore.isCorrupted, "Vault failure marks corruption rather than absence")
		#expect(failingVault.loadCount == 1, "Vault failure costs exactly one vault load")

		// Incompatible-embedder filtering on the array shape: no rewrite.
		let mixed = [makeRecord(name: "Mine"), makeRecord(embedder: "other-embedder-v9", name: "Theirs")]
		let mixedVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode(mixed))
		let (mixedStore, mixedCleanup) = makeIsolatedStore(vault: mixedVault)
		defer { mixedCleanup() }
		#expect(mixedStore.faces.count == 1 && mixedStore.faces[0].name == "Mine", "Array records from another embedder are filtered")
		#expect(!mixedStore.isCorrupted, "Filtered array is not corruption")
		#expect(mixedVault.storeCount == 0, "Filtered array never rewrites the vault")

		// Legacy single record from another embedder: nothing usable, so no migration.
		let unusableLegacyVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode(makeRecord(embedder: "other-embedder-v9")))
		let (unusableStore, unusableCleanup) = makeIsolatedStore(vault: unusableLegacyVault)
		defer { unusableCleanup() }
		#expect(unusableStore.faces.isEmpty, "Unusable legacy record yields no faces")
		#expect(!unusableStore.isCorrupted, "Unusable legacy record is not corruption")
		#expect(unusableLegacyVault.loadCount == 1, "Unusable legacy record costs exactly one vault load")
		#expect(unusableLegacyVault.storeCount == 0, "Unusable legacy record triggers no migration write")

		// Failed migration write: decoded legacy faces are retained in memory.
		let failedMigrationVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode(makeRecord(name: "Legacy")))
		failedMigrationVault.storeError = InMemoryEnrollmentVault.SimulatedFailure()
		let (failedMigrationStore, failedMigrationCleanup) = makeIsolatedStore(vault: failedMigrationVault)
		defer { failedMigrationCleanup() }
		#expect(failedMigrationStore.faces.count == 1 && failedMigrationStore.faces[0].name == "Legacy", "Failed migration retains decoded legacy faces")
		#expect(!failedMigrationStore.isCorrupted, "Failed migration write does not mark corruption")
		#expect(failedMigrationVault.loadCount == 1, "Failed migration costs exactly one vault load")
	}

	@Test func recordCompatibilityAndRoundTripEncoding() throws {
		// Records written before the switch existed carry no isEnabled key.
		let oldRecord: [String: Any] = [
			"id": UUID().uuidString,
			"name": "Old",
			"prints": [["values": [1.0, 0.0], "source": "fixture-embedder-v1"]],
			"embedder": "fixture-embedder-v1",
			"cameraID": "camera-1",
			"enrolledAt": 0.0,
		]
		let decodedOld = try JSONDecoder().decode(
			FaceEnrollment.self,
			from: JSONSerialization.data(withJSONObject: oldRecord)
		)
		#expect(decodedOld.isEnabled, "A record without isEnabled decodes as enabled")
		#expect(
			decodedOld.learnedPrints.isEmpty && decodedOld.upperPrints.isEmpty,
			"A record without learnedPrints or upperPrints decodes both as empty"
		)
		#expect(makeRecord().isEnabled, "A newly created face is enabled by default")

		// Records written before learned prints and mask matching existed carry neither key.
		let bareRecord: [String: Any] = [
			"id": UUID().uuidString,
			"name": "Bare",
			"prints": [["values": [1.0, 0.0], "source": "fixture-embedder-v1"]],
			"embedder": "fixture-embedder-v1",
			"cameraID": "camera-1",
			"enrolledAt": 0.0,
			"isEnabled": true,
		]
		let decodedBare = try JSONDecoder().decode(
			FaceEnrollment.self,
			from: JSONSerialization.data(withJSONObject: bareRecord)
		)
		#expect(decodedBare.learnedPrints.isEmpty, "A record without learnedPrints decodes as none learned")
		#expect(decodedBare.upperPrints.isEmpty, "A record without upperPrints decodes as none")

		// Learned prints and upper prints round-trip through the vault encoding.
		let seeded = FaceEnrollment(
			name: "Seeded",
			prints: [Faceprint(values: [1, 0], source: "fixture-embedder-v1")],
			learnedPrints: [learnedCandidate(0)],
			upperPrints: [Faceprint(values: [0, 1], source: "fixture-embedder-v1")],
			embedder: "fixture-embedder-v1",
			cameraID: "camera-1"
		)
		let roundTripped = try JSONDecoder().decode(FaceEnrollment.self, from: JSONEncoder().encode(seeded))
		#expect(roundTripped.learnedPrints == seeded.learnedPrints, "learnedPrints round-trip through the vault encoding")
		#expect(roundTripped.upperPrints == seeded.upperPrints, "upperPrints round-trip through the vault encoding")
	}

	@Test func faceEnablementControlsMatchingAndPersists() async throws {
		let sample = try await makeUsableSample()

		// A disabled face never matches, even with an identical print.
		let soloVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode([makeRecord(name: "Solo")]))
		let (soloStore, soloCleanup) = makeIsolatedStore(vault: soloVault)
		defer { soloCleanup() }
		#expect(soloStore.matches(sample).matched, "An enabled face matches its own print")
		#expect(soloStore.anyEnabled, "A fresh store has a face enabled")
		soloStore.setEnabled(soloStore.faces[0].id, false)
		#expect(!soloStore.faces[0].isEnabled, "setEnabled switches the face off")
		#expect(!soloStore.anyEnabled, "One switched-off face reads as none enabled")
		let persisted = try JSONDecoder().decode([FaceEnrollment].self, from: try #require(soloVault.storedPlaintext))
		#expect(persisted.count == 1 && !persisted[0].isEnabled, "setEnabled persists the switch-off")
		let switchedOff = soloStore.matches(sample)
		#expect(!switchedOff.matched && switchedOff.face == nil, "A disabled face never matches, even with an identical print")
		#expect(switchedOff.reason == FaceEnrollmentStore.allFacesOffMessage, "A lone switched-off face carries the shared reason")

		// All faces off means no match; switching one back on restores it.
		let pairVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode([makeRecord(name: "A"), makeRecord(name: "B")]))
		let (pairStore, pairCleanup) = makeIsolatedStore(vault: pairVault)
		defer { pairCleanup() }
		pairStore.setEnabled(pairStore.faces[0].id, false)
		pairStore.setEnabled(pairStore.faces[1].id, false)
		let none = pairStore.matches(sample)
		#expect(!none.matched && none.face == nil, "All faces off means no match")
		#expect(none.reason == FaceEnrollmentStore.allFacesOffMessage, "All faces off carries the shared reason")
		pairStore.setEnabled(pairStore.faces[0].id, true)
		#expect(pairStore.anyEnabled, "Switching one face back on reads as enabled")
		#expect(pairStore.matches(sample).matched, "A re-enabled face matches again")
	}

	@Test func learningGuardsCapRevertAndOriginalAnchoring() async throws {
		let sample = try await makeUsableSample()

		// Learning: the drift guard, the near-duplicate skip, the cap of eight.
		let cappedRecord = FaceEnrollment(
			name: "Capped",
			prints: [fp([1, 0])],
			learnedPrints: (0..<8).map { _ in fp([1, 0]) },
			embedder: "fixture-embedder-v1",
			cameraID: "camera-1"
		)
		let cappedVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode([cappedRecord]))
		let (cappedStore, cappedCleanup) = makeIsolatedStore(vault: cappedVault)
		defer { cappedCleanup() }
		let cappedFaceID = cappedStore.faces[0].id
		let writesBeforeLearning = cappedVault.storeCount

		// A print unlike the originals is refused — the face cannot drift.
		cappedStore.learn(fp([0, 1]), for: cappedFaceID)
		#expect(cappedStore.faces[0].learnedPrints.count == 8, "A print unlike the originals is not learned")

		// A near-duplicate of a learned print is skipped.
		cappedStore.learn(fp([1, 0]), for: cappedFaceID)
		#expect(cappedStore.faces[0].learnedPrints.count == 8, "A near-duplicate of a learned print is skipped")

		// A new angle of the same face is learned, and the oldest is dropped.
		cappedStore.learn(fp([0.8, 0.6]), for: cappedFaceID)
		#expect(cappedStore.faces[0].learnedPrints.count == 8, "The learned set stays capped at eight")
		#expect(cappedStore.faces[0].learnedPrints.last == fp([0.8, 0.6]), "Learning at the cap drops the oldest")
		#expect(cappedVault.storeCount == writesBeforeLearning + 1, "Learning persists to the vault")

		// An unknown face is a no-op, not a crash and not a write.
		cappedStore.learn(fp([1, 0]), for: UUID())
		#expect(cappedVault.storeCount == writesBeforeLearning + 1, "Learning an unknown face writes nothing")

		// A failed write reverts the learned print.
		cappedVault.storeError = InMemoryEnrollmentVault.SimulatedFailure()
		cappedStore.learn(fp([0.95, 0.312]), for: cappedFaceID)
		#expect(
			cappedStore.faces[0].learnedPrints.last == fp([0.8, 0.6]) && cappedStore.faces[0].learnedPrints.count == 8,
			"A failed learn write reverts the print"
		)
		cappedVault.storeError = nil

		// Learned prints alone can never authorise a match.
		let originalsOnly = FaceEnrollment(
			name: "Originals",
			prints: [fp([0, 1]), fp([0, 1])],
			embedder: "fixture-embedder-v1",
			cameraID: "camera-1"
		)
		let origVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode([originalsOnly]))
		let (origStore, origCleanup) = makeIsolatedStore(vault: origVault)
		defer { origCleanup() }
		#expect(!origStore.matches(sample).matched, "A face whose originals do not match does not match")

		let withLearned = FaceEnrollment(
			name: "WithLearned",
			prints: [fp([0, 1]), fp([0, 1])],
			learnedPrints: [fp([1, 0]), fp([1, 0])],
			embedder: "fixture-embedder-v1",
			cameraID: "camera-1"
		)
		let learnedOnlyVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode([withLearned]))
		let (learnedOnlyStore, learnedOnlyCleanup) = makeIsolatedStore(vault: learnedOnlyVault)
		defer { learnedOnlyCleanup() }
		#expect(!learnedOnlyStore.matches(sample).matched, "Learned prints alone never authorise a match")

		// Learning banks a qualifying print, skips duplicates, rejects drifters, caps at 8, ignores unknown/foreign.
		let learnerBase = learnedBase()
		let learnerRecord = FaceEnrollment(
			name: "Learner",
			prints: [learnerBase, learnerBase],
			embedder: "fixture-embedder-v1",
			cameraID: "camera-1"
		)
		let learnerVault = InMemoryEnrollmentVault(plaintext: try JSONEncoder().encode([learnerRecord]))
		let (learnerStore, learnerCleanup) = makeIsolatedStore(vault: learnerVault)
		defer { learnerCleanup() }
		let learnerID = learnerStore.faces[0].id
		#expect(learnerStore.faces[0].learnedPrints.isEmpty, "A fresh face has no learned prints")
		learnerStore.learn(learnedCandidate(0), for: learnerID)
		#expect(learnerStore.faces[0].learnedPrints.count == 1, "A distinct qualifying print is learned")
		let learnedPersisted = try JSONDecoder().decode([FaceEnrollment].self, from: try #require(learnerVault.storedPlaintext))
		#expect(learnedPersisted[0].learnedPrints.count == 1, "learn persists the learned print")

		let writesAfterFirst = learnerVault.storeCount
		learnerStore.learn(learnerStore.faces[0].learnedPrints[0], for: learnerID)
		#expect(learnerStore.faces[0].learnedPrints.count == 1, "A near-duplicate of a learned print is skipped")
		#expect(learnerVault.storeCount == writesAfterFirst, "A skipped duplicate writes nothing")

		var drifter = [Float](repeating: 0, count: 12)
		drifter[3] = 1
		learnerStore.learn(Faceprint(values: drifter, source: "fixture-embedder-v1"), for: learnerID)
		#expect(learnerStore.faces[0].learnedPrints.count == 1, "A print far from the original prints is rejected")

		for index in 1...8 {
			learnerStore.learn(learnedCandidate(index), for: learnerID)
		}
		#expect(learnerStore.faces[0].learnedPrints.count == 8, "Learned prints are capped at 8")
		#expect(!learnerStore.faces[0].learnedPrints.contains(learnedCandidate(0)), "The oldest learned print drops when full")

		let beforeIgnored = learnerStore.faces[0].learnedPrints.count
		learnerStore.learn(learnedCandidate(9), for: UUID())
		learnerStore.learn(learnedCandidate(9, source: "other-embedder-v9"), for: learnerID)
		#expect(learnerStore.faces[0].learnedPrints.count == beforeIgnored, "Unknown faces and foreign prints are ignored")
	}
}
