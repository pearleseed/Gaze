import AppKit
@preconcurrency import AVFoundation
import CoreImage
import GazeCore
import Observation
import Synchronization
import Vision

/// Why there is no usable face in the frame.
///
/// A reason rather than a boolean, because the two common cases need opposite responses
/// from the user and the app used to word them identically. `nil` means there *is* a face.
package enum FaceAbsence: Equatable, Sendable {
	/// Nobody in frame.
	case noFace
	/// More than one face, so the app declines to guess which is the user. Also the
	/// shoulder-surfing case, which is why refusing is the safe default rather than
	/// picking the largest.
	case multipleFaces(Int)
	/// Vision could not run the detector on the frame at all.
	case detectionFailed
	/// A face was found but the landmark or quality pass failed on it.
	case analysisFailed

	/// One short line, for the test window.
	package var summary: String {
		switch self {
		case .noFace: return "No face"
		case .multipleFaces(let count): return "\(count) faces in frame"
		case .detectionFailed: return "Couldn't read the frame"
		case .analysisFailed: return "Face found, couldn't measure it"
		}
	}
}

/// One usable look at a face: the geometry Vision found, plus the frame it came from.
/// `@unchecked Sendable` for immutable Vision `VNFaceLandmarks2D` and read-only `CVPixelBuffer` handles.
package struct FaceSample: @unchecked Sendable {
	package let landmarks: VNFaceLandmarks2D
	package let boundingBox: CGRect
	package let pose: FacePose
	/// Vision's own view of whether this frame is good enough to identify from.
	package let quality: Float
	/// A reported zero means unusable; missing quality is a separate state.
	package var hasQualityMeasurement: Bool
	package let pixelBuffer: CVPixelBuffer
	/// Other faces in the same frame, largest first, when bystanders are allowed. Each is
	/// matched on its own; the one that matches an enrolled face is the one used.
	package var bystanders: [FaceSample]

	package init(
		landmarks: VNFaceLandmarks2D,
		boundingBox: CGRect,
		pose: FacePose,
		quality: Float,
		hasQualityMeasurement: Bool = true,
		pixelBuffer: CVPixelBuffer,
		bystanders: [FaceSample] = []
	) {
		self.landmarks = landmarks
		self.boundingBox = boundingBox
		self.pose = pose
		self.quality = quality
		self.hasQualityMeasurement = hasQualityMeasurement
		self.pixelBuffer = pixelBuffer
		self.bystanders = bystanders
	}
}

/// Controls how much per-frame Vision work `CameraController` runs.
package enum CameraAnalysisMode: Sendable, Equatable {
	/// Runs face rectangles, landmarks, and capture quality for recognition and liveness.
	case full
	/// Runs only face rectangle detection for lightweight presence checks.
	case presenceOnly
}

/// Lightweight presence-only analysis result emitted when `CameraAnalysisMode.presenceOnly` is active.
package struct PresenceObservation: Sendable, Equatable {
	package enum Verdict: Sendable, Equatable {
		case facePresent
		case noFace
		case indeterminate
	}

	package let verdict: Verdict
	package let frameID: UInt64
	package let capturedAt: ContinuousClock.Instant

	package init(verdict: Verdict, frameID: UInt64, capturedAt: ContinuousClock.Instant) {
		self.verdict = verdict
		self.frameID = frameID
		self.capturedAt = capturedAt
	}
}

/// Bounded 1-slot handoff between the capture queue and `MainActor`.
///
/// Overwrites any unconsumed element when the producer outruns `MainActor` so at
/// most one pending buffer is retained in memory, while counting overwrites so
/// continuity checks never treat non-contiguous frames as unbroken proof.
package struct LatestFrameMailbox<Element: Sendable>: Sendable {
	private struct State: Sendable {
		var pending: Element?
		var dropped = 0
		var drainScheduled = false
	}

	private final class Storage: Sendable {
		let state = Mutex(State())
	}

	private let storage = Storage()

	package init() {}

	/// Stores `element` as the sole pending item, overwriting any unconsumed item.
	/// Returns `true` only when transitioning from idle to a scheduled drain so at
	/// most one `MainActor` drain task is scheduled at a time.
	package func enqueue(_ element: Element) -> Bool {
		storage.state.withLock { state in
			if state.pending != nil {
				state.dropped &+= 1
			}
			state.pending = element
			guard !state.drainScheduled else { return false }
			state.drainScheduled = true
			return true
		}
	}

	/// Atomically extracts the latest pending element and the number of items
	/// overwritten before it since the previous drain.
	package func take() -> (element: Element, droppedBefore: Int)? {
		storage.state.withLock { state in
			guard let element = state.pending else { return nil }
			let droppedBefore = state.dropped
			state.pending = nil
			state.dropped = 0
			state.drainScheduled = false
			return (element, droppedBefore)
		}
	}

	/// Discards any pending element and resets the scheduled flag.
	package func clear() {
		storage.state.withLock { state in
			state.pending = nil
			state.dropped = 0
			state.drainScheduled = false
		}
	}
}

/// Tracks the currently scheduled `MainActor` drain task for a single capture
/// session so `stop()` can cancel it and block late `frameQueue` scheduling.
private final class DrainCoordinator: Sendable {
	private struct State: Sendable {
		var stopped = false
		var task: Task<Void, Never>?
	}

	private let state = Mutex(State())

	func schedule(_ operation: @escaping @MainActor () -> Void) {
		state.withLock { state in
			guard !state.stopped else { return }
			state.task = Task { @MainActor in
				operation()
			}
		}
	}

	func cancel() {
		let pending = state.withLock { state -> Task<Void, Never>? in
			state.stopped = true
			let task = state.task
			state.task = nil
			return task
		}
		pending?.cancel()
	}
}

/// Owns the capture session and turns frames into `FaceSample`s.
///
/// The session only ever binds to the built-in camera — see `CameraDevice` for why
/// that is a security control and not just a convenience.
@Observable
@MainActor
package final class CameraController {

	/// Whether the lock screen may ask for Follow the light: movements on, it not
	/// switched off, and Reduce Motion off (Reduce Motion swaps the light for another
	/// movement). Read from defaults so the camera needs no Preferences.
	package static var followLightOffered: Bool {
		guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
		let defaults = UserDefaults.standard
		guard defaults.integer(forKey: "unlockMovementCount") > 0 || defaults.object(forKey: "unlockMovementCount") == nil
		else { return false }
		return !(defaults.stringArray(forKey: "disabledMovements") ?? []).contains("followLight")
	}

	package enum State: Equatable, Sendable {
		case idle
		case denied
		case failed(String)
		case running
	}

	package let analysisMode: CameraAnalysisMode
	package private(set) var state: State = .idle
	package private(set) var evidenceContinuity = CameraEvidenceContinuity()
	/// The most recent frame containing exactly one usable face.
	package private(set) var sample: FaceSample?
	/// True when a face was expected but the frame had none, or had several.
	package private(set) var faceMissing = true
	/// Why, when `faceMissing` is true. Nil while a face is present.
	package private(set) var absence: FaceAbsence? = .noFace

	/// Increments on every delivered frame.
	///
	/// Observers must drive off this rather than off `sample`, because two consecutive
	/// frames can carry an identical pose — a perfectly still head, or a Vision revision
	/// that doesn't populate yaw/pitch at all — and an observer watching the pose alone
	/// would then simply stop being called.
	package private(set) var frameID: UInt64 = 0
	package private(set) var analyzedFrames: UInt64 = 0
	package private(set) var expiredFrames: UInt64 = 0

	/// `uniqueID` of the camera this session is bound to, recorded at enrolment.
	package private(set) var boundDeviceID: String?
	package private(set) var lastFrameCapturedAt: ContinuousClock.Instant?
	/// Observes every analysis result on the main actor, including rejected frames
	/// as indeterminate results. Polling only the latest frame can miss a brief face.
	package var onFrameAnalyzed: (@MainActor (FaceAbsence?, UInt64, ContinuousClock.Instant) -> Void)?
	/// Observes lightweight presence results when configured with `CameraAnalysisMode.presenceOnly`.
	package var onPresenceObserved: (@MainActor (PresenceObservation) -> Void)?
	private let capture = CameraCaptureDriver()
	private var lease = CameraFrameLease()
	private var starting = false
	private var clearPendingDelivery: (() -> Void)?
	private var observers: [NSObjectProtocol] = []
	private let sessionGate: CameraSessionGate

	/// `allowsBystanders`: when several faces are in view, analyse up to three of them and
	/// let recognition pick the enrolled one, instead of refusing the frame. On by default at the lock screen only; setup
	/// keeps the strict one-face rule so a bystander can never be enrolled.
	package init(
		accessScope: CameraSessionGate.Scope = .foreground,
		allowsBystanders: Bool? = nil,
		analysisMode: CameraAnalysisMode = .full
	) {
		self.analysisMode = analysisMode
		sessionGate = CameraSessionGate(scope: accessScope)
		capture.analysisMode = analysisMode
		capture.allowsBystanders = allowsBystanders ?? (accessScope == .lockScreen)
		// 720p is quicker to scan, but it leaves the eyes too few pixels for the iris
		// model: Follow the light only worked leaning in. Keep full size while it can be asked for.
		// Presence-only mode runs only face rectangles, so 720p/30fps is always sufficient.
		capture.fastFrames = analysisMode == .presenceOnly || (accessScope == .lockScreen && !Self.followLightOffered)
		for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
			observers.append(NotificationCenter.default.addObserver(forName: name, object: capture.session, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self, self.lease.generation != nil else { return }
					self.stop()
					self.state = .failed("Camera capture was interrupted. Try again.")
				}
			})
		}
	}

	// MARK: - Lifecycle

	package func start(pinnedDeviceID: String? = nil) async {
		guard state != .running, !starting, !Task.isCancelled else { return }
		let generation = lease.begin()
		analyzedFrames = 0
		expiredFrames = 0
		starting = true
		defer { if lease.generation == generation { starting = false } }
		guard sessionGate.begin(onInvalidation: { [weak self] in
			guard let self, self.lease.generation == generation else { return }
			self.stop()
			self.state = .failed("Camera paused when the Mac locked, slept or changed users. Reopen this window after unlocking to restart it.")
		}) else {
			// The lease generation was already minted above; release it so nothing
			// reads an open lease as an active capture.
			lease.stop()
			return
		}

		let authorized = await requestAccess()
		guard lease.generation == generation, sessionGate.isValid else { return }
		guard !Task.isCancelled else { stop(); return }
		guard authorized else {
			stop()
			state = .denied
			return
		}

		let device: AVCaptureDevice
		do {
			device = try CameraDevice.trusted(pinnedID: pinnedDeviceID, allowExternal: Preferences.shared.allowExternalCamera)
		} catch {
			stop()
			state = .failed(String(describing: error))
			return
		}

		let mailbox = LatestFrameMailbox<SampleProxy.Output>()
		let drain = DrainCoordinator()
		clearPendingDelivery = {
			drain.cancel()
			mailbox.clear()
		}

		do {
			let running = try await capture.start(with: device) { [weak self] output in
				let capturedAt = output.capturedAt
				// Drop already-stale frames before the mailbox hop: mirrors the lease
				// age check below; generation is still checked on-actor.
				guard capturedAt <= .now, capturedAt.duration(to: .now) <= CameraFrameLease.maximumAge else { return }
				guard mailbox.enqueue(output) else { return }
				drain.schedule { [weak self] in
					// Always drain the mailbox slot first so an early pre-running frame
					// cannot leave `drainScheduled` stuck true and strand later frames.
					guard let delivery = mailbox.take() else { return }
					guard let self, !Task.isCancelled, self.state == .running,
						self.lease.generation == generation, self.sessionGate.isValid else { return }
					self.deliver(delivery.element, droppedBefore: delivery.droppedBefore, generation: generation)
				}
			}
			guard lease.generation == generation, sessionGate.isValid else { return }
			guard !Task.isCancelled else { stop(); return }
			guard running else {
				stop()
				state = .failed("The camera did not start delivering video.")
				return
			}
		} catch {
			guard lease.generation == generation else { return }
			stop()
			state = .failed(error.localizedDescription)
			return
		}

		boundDeviceID = device.uniqueID
		state = .running
	}

	private func deliver(_ output: SampleProxy.Output, droppedBefore: Int, generation: UUID) {
		if droppedBefore > 0 {
			analyzedFrames &+= UInt64(droppedBefore)
		}
		analyzedFrames &+= 1
		let capturedAt = output.capturedAt
		let now = ContinuousClock.now

		switch output {
		case .full(let sample, let absence, _):
			guard lease.accepts(generation, capturedAt: capturedAt, now: now) else {
				if droppedBefore > 0 { evidenceContinuity.invalidate() }
				expiredFrames &+= 1
				onFrameAnalyzed?(.detectionFailed, analyzedFrames, capturedAt)
				return
			}
			let usable = absence == nil && sample.map { FrameQuality.isUsable($0) } == true
			guard evidenceContinuity.record(usable: usable, capturedAt: capturedAt, droppedBefore: droppedBefore) else {
				onFrameAnalyzed?(.detectionFailed, analyzedFrames, capturedAt)
				return
			}
			self.sample = sample
			self.absence = absence
			self.faceMissing = absence != nil
			self.lastFrameCapturedAt = capturedAt
			self.frameID &+= 1
			onFrameAnalyzed?(absence, analyzedFrames, capturedAt)

		case .presence(let verdict, _):
			guard lease.accepts(generation, capturedAt: capturedAt, now: now) else {
				if droppedBefore > 0 { evidenceContinuity.invalidate() }
				expiredFrames &+= 1
				onPresenceObserved?(PresenceObservation(verdict: .indeterminate, frameID: analyzedFrames, capturedAt: capturedAt))
				onFrameAnalyzed?(.detectionFailed, analyzedFrames, capturedAt)
				return
			}
			guard evidenceContinuity.record(usable: false, capturedAt: capturedAt, droppedBefore: droppedBefore) else {
				onPresenceObserved?(PresenceObservation(verdict: .indeterminate, frameID: analyzedFrames, capturedAt: capturedAt))
				onFrameAnalyzed?(.detectionFailed, analyzedFrames, capturedAt)
				return
			}
			if droppedBefore > 0 && verdict == .noFace {
				// Overwritten frames may have held a brief face; emit an indeterminate
				// break first so `PresenceAbsenceGate` restarts instead of bridging across drops.
				onPresenceObserved?(PresenceObservation(verdict: .indeterminate, frameID: analyzedFrames &- 1, capturedAt: capturedAt))
			}
			let mappedAbsence: FaceAbsence? = switch verdict {
			case .facePresent: nil
			case .noFace: .noFace
			case .indeterminate: .detectionFailed
			}
			self.sample = nil
			self.absence = mappedAbsence
			self.faceMissing = verdict != .facePresent
			self.lastFrameCapturedAt = capturedAt
			self.frameID &+= 1
			onPresenceObserved?(PresenceObservation(verdict: verdict, frameID: analyzedFrames, capturedAt: capturedAt))
			onFrameAnalyzed?(mappedAbsence, analyzedFrames, capturedAt)
		}
	}

	package func stop() {
		clearPendingDelivery?()
		clearPendingDelivery = nil
		sessionGate.end()
		evidenceContinuity.invalidate()
		lease.stop()
		starting = false
		capture.stop()
		state = .idle
		sample = nil
		faceMissing = true
		absence = .noFace
		boundDeviceID = nil
		lastFrameCapturedAt = nil
	}

	private func requestAccess() async -> Bool {
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized: return true
		case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
		default: return false
		}
	}

	package func previewLayer() -> AVCaptureVideoPreviewLayer {
		let layer = AVCaptureVideoPreviewLayer(session: capture.session)
		layer.videoGravity = .resizeAspectFill
		return layer
	}

	isolated deinit {
		clearPendingDelivery?()
		clearPendingDelivery = nil
		sessionGate.end()
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
		capture.stop()
	}
}

/// `@unchecked Sendable`: wraps non-Sendable AVFoundation capture handles (`AVCaptureSession`,
/// `AVCaptureVideoDataOutput`) and serialises all capture-session mutations on `sessionQueue`
/// (with `allowsBystanders`, `fastFrames`, and `analysisMode` configured once on `MainActor` before `start`).
private final class CameraCaptureDriver: @unchecked Sendable {
	let session = AVCaptureSession()
	private let output = AVCaptureVideoDataOutput()
	private let sessionQueue = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).session", qos: .userInitiated)
	private let frameQueue = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).capture", qos: .userInitiated)
	private var proxy: SampleProxy?
	var analysisMode: CameraAnalysisMode = .full
	var allowsBystanders = false
	/// Smaller frames reach a first match sooner; enrolment keeps full size.
	var fastFrames = false

	func start(with device: AVCaptureDevice,
		onOutput: @escaping @Sendable (SampleProxy.Output) -> Void) async throws -> Bool {
		try await withCheckedThrowingContinuation { continuation in
			sessionQueue.async { [self] in
				do {
					try configure(with: device, onOutput: onOutput)
					session.startRunning()
					continuation.resume(returning: session.isRunning)
				} catch { continuation.resume(throwing: error) }
			}
		}
	}

	func stop() {
		sessionQueue.async { [self] in
			output.setSampleBufferDelegate(nil, queue: nil)
			if session.isRunning { session.stopRunning() }
			proxy = nil
		}
	}

	private func configure(with device: AVCaptureDevice,
		onOutput: @escaping @Sendable (SampleProxy.Output) -> Void) throws {
		session.beginConfiguration()
		defer { session.commitConfiguration() }

		session.sessionPreset = fastFrames && session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

		if fastFrames {
			// Cap the sensor at 30 fps so Vision sees lighter frames sooner.
			do {
				try device.lockForConfiguration()
				defer { device.unlockForConfiguration() }
				if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate }) {
					device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
				}
			} catch {}
		}

		session.inputs.forEach(session.removeInput)
		let input = try AVCaptureDeviceInput(device: device)
		guard session.canAddInput(input) else {
			throw NSError(
				domain: AppIdentity.bundleIdentifier, code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Could not read from the built-in camera."])
		}
		session.addInput(input)

		let proxy = SampleProxy(analysisMode: analysisMode, allowsBystanders: allowsBystanders, onOutput: onOutput)
		self.proxy = proxy

		output.videoSettings = [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
		]
		// Analysing stale frames just delays recognition, so drop rather than queue.
		output.alwaysDiscardsLateVideoFrames = true
		output.setSampleBufferDelegate(proxy, queue: frameQueue)

		session.outputs.forEach(session.removeOutput)
		guard session.canAddOutput(output) else {
			throw NSError(
				domain: AppIdentity.bundleIdentifier, code: 2,
				userInfo: [NSLocalizedDescriptionKey: "Could not attach the video output."])
		}
		session.addOutput(output)
	}
}

// MARK: - Vision

/// Abstracts Vision request execution per frame so `SampleProxy` can be tested
/// deterministically without camera hardware.
package protocol FaceVisionRunning {
	func detectRectangles(using request: VNDetectFaceRectanglesRequest) throws -> [VNFaceObservation]
	func analyseFace(
		_ face: VNFaceObservation,
		using landmarksRequest: VNDetectFaceLandmarksRequest,
		qualityRequest: VNDetectFaceCaptureQualityRequest,
		buffer: CVPixelBuffer
	) -> FaceSample?
}

private struct VisionFrameRunner: FaceVisionRunning {
	private let handler: VNImageRequestHandler

	init(buffer: CVPixelBuffer) {
		self.handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
	}

	func detectRectangles(using request: VNDetectFaceRectanglesRequest) throws -> [VNFaceObservation] {
		try handler.perform([request])
		return request.results ?? []
	}

	/// Landmarks, capture quality and pose for one detected face.
	func analyseFace(
		_ face: VNFaceObservation,
		using landmarksRequest: VNDetectFaceLandmarksRequest,
		qualityRequest: VNDetectFaceCaptureQualityRequest,
		buffer: CVPixelBuffer
	) -> FaceSample? {
		landmarksRequest.inputFaceObservations = [face]
		qualityRequest.inputFaceObservations = [face]
		do { try handler.perform([landmarksRequest, qualityRequest]) } catch { return nil }
		guard let landmarks = landmarksRequest.results?.first?.landmarks else { return nil }
		// A reported zero means unusable; a missing measurement is a separate state.
		let quality = qualityRequest.results?.first?.faceCaptureQuality

		// Vision's own estimate when it gives one, geometry when it doesn't, per-axis
		// provenance always. Some revisions populate yaw but leave pitch nil, so the
		// axes decide separately, and a missing landmark estimate lands as
		// NaN/unavailable — never as a frontal zero the challenge could mistake for
		// a held-still head.
		let pose = FacePose.resolved(
			visionYaw: face.yaw?.doubleValue,
			visionPitch: face.pitch?.doubleValue,
			visionRoll: face.roll?.doubleValue,
			estimate: FacePose.estimate(from: landmarks))
		return FaceSample(landmarks: landmarks, boundingBox: face.boundingBox, pose: pose,
			quality: quality ?? 0, hasQualityMeasurement: quality != nil, pixelBuffer: buffer)
	}
}

/// Runs Vision off the main actor and hands finished samples back.
package final class SampleProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
	package enum Output: Sendable {
		case full(sample: FaceSample?, absence: FaceAbsence?, capturedAt: ContinuousClock.Instant)
		case presence(verdict: PresenceObservation.Verdict, capturedAt: ContinuousClock.Instant)

		var capturedAt: ContinuousClock.Instant {
			switch self {
			case .full(_, _, let capturedAt), .presence(_, let capturedAt):
				return capturedAt
			}
		}
	}

	private let analysisMode: CameraAnalysisMode
	private let onOutput: @Sendable (Output) -> Void
	private let makeVisionRunner: @Sendable (CVPixelBuffer) -> any FaceVisionRunning
	private let rectanglesRequest = VNDetectFaceRectanglesRequest()
	private let landmarksRequest = VNDetectFaceLandmarksRequest()
	private let qualityRequest = VNDetectFaceCaptureQualityRequest()
	private let allowsBystanders: Bool

	package init(
		analysisMode: CameraAnalysisMode = .full,
		allowsBystanders: Bool = false,
		makeVisionRunner: @escaping @Sendable (CVPixelBuffer) -> any FaceVisionRunning = { VisionFrameRunner(buffer: $0) },
		onOutput: @escaping @Sendable (Output) -> Void
	) {
		self.analysisMode = analysisMode
		self.allowsBystanders = allowsBystanders
		self.makeVisionRunner = makeVisionRunner
		self.onOutput = onOutput

		// Pose comes from the *rectangles* request, not the landmarks one, and only from
		// revision 3 onwards. Running landmarks alone returns observations whose yaw and
		// pitch are nil, which reads downstream as a head that never moves.
		if VNDetectFaceRectanglesRequest.supportedRevisions.contains(
			VNDetectFaceRectanglesRequestRevision3)
		{
			rectanglesRequest.revision = VNDetectFaceRectanglesRequestRevision3
		}
	}

	package static func presenceVerdict(detectedCount: Int, detectionSucceeded: Bool) -> PresenceObservation.Verdict {
		guard detectionSucceeded, detectedCount >= 0 else { return .indeterminate }
		return detectedCount > 0 ? .facePresent : .noFace
	}

	/// Faces analysed per frame when bystanders are allowed. Recognition runs on each, so
	/// this bounds the per-frame cost.
	static let maximumCandidates = 3

	/// The faces to analyse, largest first: the only one, or with bystanders allowed up to
	/// `maximumCandidates`. Recognition then decides which one, if any, is enrolled.
	static func candidateFaces(in faces: [VNFaceObservation], allowsBystanders: Bool) -> [VNFaceObservation] {
		if faces.count == 1 { return faces }
		guard allowsBystanders, faces.count > 1 else { return [] }
		// Faces below FrameQuality.minFaceHeight can never be used downstream
		// (LockWatcher filters every candidate through FrameQuality.rejection before
		// matching), so drop them before the landmark pass instead of analysing them.
		return Array(faces.filter { $0.boundingBox.height >= FrameQuality.minFaceHeight }
			.sorted { $0.boundingBox.area > $1.boundingBox.area }.prefix(maximumCandidates))
	}

	package func captureOutput(
		_ output: AVCaptureOutput,
		didOutput sampleBuffer: CMSampleBuffer,
		from connection: AVCaptureConnection
	) {
		let capturedAt = ContinuousClock.now
		guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
		process(buffer: buffer, capturedAt: capturedAt)
	}

	package func process(buffer: CVPixelBuffer, capturedAt: ContinuousClock.Instant) {
		if analysisMode == .full {
			SceneBrightness.record(buffer, at: capturedAt)
		}

		let runner = makeVisionRunner(buffer)

		// Detect once, then hand the same observation to the two follow-up requests
		// rather than letting each re-detect. In `.presenceOnly` mode, stop after
		// rectangles so neither landmarks/quality nor pixel buffers leave this queue.
		let detected: [VNFaceObservation]
		do {
			detected = try runner.detectRectangles(using: rectanglesRequest)
		} catch {
			switch analysisMode {
			case .presenceOnly:
				onOutput(.presence(verdict: Self.presenceVerdict(detectedCount: 0, detectionSucceeded: false), capturedAt: capturedAt))
			case .full:
				onOutput(.full(sample: nil, absence: .detectionFailed, capturedAt: capturedAt))
			}
			return
		}

		if analysisMode == .presenceOnly {
			let verdict = Self.presenceVerdict(detectedCount: detected.count, detectionSucceeded: true)
			onOutput(.presence(verdict: verdict, capturedAt: capturedAt))
			return
		}

		// Exactly one face during enrolment, or we decline to guess which one is the
		// user. Two faces in frame is also the shoulder-surfing case, so refusing is
		// the safe default there. The lock screen and Test Recognition (allowsBystanders)
		// analyse up to three faces and use the one that matches.
		// Exactly one, and the count is worth reporting rather than flattening.
		//
		// "No face" was shown for both an empty room and a room with two faces in it, which
		// are opposite problems: one means step closer, the other means something in the
		// background is being read as a person. Anybody debugging the second one from the
		// first one's wording is going to conclude the camera is broken.
		let candidates = Self.candidateFaces(in: detected, allowsBystanders: allowsBystanders)
		guard !candidates.isEmpty else {
			onOutput(.full(sample: nil, absence: detected.isEmpty ? .noFace : .multipleFaces(detected.count), capturedAt: capturedAt))
			return
		}
		let samples = candidates.compactMap {
			runner.analyseFace($0, using: landmarksRequest, qualityRequest: qualityRequest, buffer: buffer)
		}
		guard var primary = samples.first else {
			onOutput(.full(sample: nil, absence: .analysisFailed, capturedAt: capturedAt))
			return
		}
		primary.bystanders = Array(samples.dropFirst())
		onOutput(.full(sample: primary, absence: nil, capturedAt: capturedAt))
	}
}

private extension CGRect {
	var area: CGFloat { width * height }
}
