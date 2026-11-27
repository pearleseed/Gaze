import CoreVideo
import Foundation
import GazeCamera

package actor UnlockFrameEvaluator {
	package enum Failure: String, Sendable {
		case cancelled, invalidConfiguration, embeddingUnavailable, invalidSimilarity, noEnrollment, unusableFrame
	}

	package struct Result: Sendable {
		package let matched: Bool
		package let score: Float
		package let face: FaceEnrollment?
		package let spoofDecision: AntiSpoofGate.Decision?
		package var comparedIdentity: Bool
		package var failure: Failure?
		/// The print of the frame that matched, for learning after a confirmed unlock.
		package var matchedPrint: Faceprint?
		/// True when the match came from the upper face alone (the mask path). The
		/// caller must require the movement challenge on this path, always.
		package var viaUpperFace: Bool
		package var spoofConfidence: Float? = nil
		package var didRunSpoofClassifier: Bool = false

		package init(
			matched: Bool,
			score: Float,
			face: FaceEnrollment?,
			spoofDecision: AntiSpoofGate.Decision?,
			comparedIdentity: Bool = true,
			failure: Failure? = nil,
			matchedPrint: Faceprint? = nil,
			viaUpperFace: Bool = false,
			spoofConfidence: Float? = nil,
			didRunSpoofClassifier: Bool = false
		) {
			self.matched = matched
			self.score = score
			self.face = face
			self.spoofDecision = spoofDecision
			self.comparedIdentity = comparedIdentity
			self.failure = failure
			self.matchedPrint = matchedPrint
			self.viaUpperFace = viaUpperFace
			self.spoofConfidence = spoofConfidence
			self.didRunSpoofClassifier = didRunSpoofClassifier
		}

		package func permitsMatchHold(requiresAntiSpoof: Bool) -> Bool {
			failure == nil && comparedIdentity && matched && face != nil && (requiresAntiSpoof ? spoofDecision == .live : spoofDecision == nil || spoofDecision == .live)
		}

		package static func rejected(_ failure: Failure) -> Self {
			Self(matched: false, score: 0, face: nil, spoofDecision: nil,
				comparedIdentity: false, failure: failure)
		}
	}

	private let embedder: any FaceEmbedder
	private let faces: [FaceEnrollment]
	private let antiSpoof: AntiSpoofGate?
	/// Whether the mask path may run at all. The caller only enables it alongside a
	/// movement challenge, so an upper-face match is never the sole proof.
	private let allowsMaskUnlock: Bool
	/// Faces that have upper-face prints, and where they sit in `faces`.
	private let upperMatcher: FaceTemplateMatcher?
	private let upperFaceIndices: [Int]
	/// Passive deny cues (device bezel, screen glare), adapted from Glance. Owned
	/// here — on this actor, off the main thread — rather than in `AntiSpoofGate` so
	/// the gate stays a stateless per-frame verdict and the hardening suite's stubs
	/// keep compiling against it untouched. Counts accumulate across the scan and
	/// reset per unlock attempt (fresh evaluator) or on an explicit `resetSpoofCues`.
	private var bezelCue = DeviceBezelGate()
	private var glareCue = GlareCue()
	/// Frames in this scan the classifier called a spoof. Its score swings from frame to
	/// frame on a real face (Owen's rejected lock-screen photos scored 0.00 to 0.65 while
	/// a single spiking frame rejected the attempt), so like the cues it needs several
	/// frames before it rejects. A frame it flags is still never used for a match.
	private var classifierSpoofFrames = 0
	package static let classifierFireFrames = 3
	private let matcher: FaceTemplateMatcher
	private let makeContextCrop: @Sendable (FaceSample, Int) -> CVPixelBuffer?

	package init(
		embedder: any FaceEmbedder,
		faces: [FaceEnrollment],
		antiSpoof: AntiSpoofGate?,
		allowsMaskUnlock: Bool = false,
		makeContextCrop: @escaping @Sendable (FaceSample, Int) -> CVPixelBuffer? = { FaceAligner.contextCrop($0, side: $1) }
	) {
		self.embedder = embedder
		self.faces = faces
		self.antiSpoof = antiSpoof
		self.allowsMaskUnlock = allowsMaskUnlock
		self.makeContextCrop = makeContextCrop
		// Learned prints match alongside the originals, so the face the Mac sees
		// improves with use — but the originals alone anchor the drift guard.
		self.matcher = FaceTemplateMatcher(templates: faces.map { $0.prints + $0.learnedPrints },
			originalCounts: faces.map(\.prints.count), embedder: embedder)
		let withUpper = faces.enumerated().filter { !$0.element.upperPrints.isEmpty }
		self.upperFaceIndices = withUpper.map(\.offset)
		self.upperMatcher = withUpper.isEmpty
			? nil
			: FaceTemplateMatcher(templates: withUpper.map(\.element.upperPrints), embedder: embedder)
	}

	/// Clears the deny cues' per-scan counts, so the next look after a spoof
	/// rejection starts from a clean slate like every other per-try state.
	package func resetSpoofCues() {
		bezelCue.reset()
		glareCue.reset()
		classifierSpoofFrames = 0
	}

	package func evaluate(_ sample: FaceSample, settlingExposure: Bool = false) -> Result {
		guard !Task.isCancelled else { return .rejected(.cancelled) }
		guard !faces.isEmpty else { return .rejected(.noEnrollment) }
		guard FrameQuality.isUsable(sample) else { return .rejected(.unusableFrame) }
		guard embedder.matchThreshold.isFinite,
			(0...1).contains(embedder.matchThreshold), embedder.matchThreshold > 0 else {
			return .rejected(.invalidConfiguration)
		}
		guard let candidate = embedder.embed(sample) else { return .rejected(.embeddingUnavailable) }
		let best: FaceTemplateMatcher.Match?
		do { best = try matcher.bestMatch(to: candidate) }
		catch { return .rejected(.invalidSimilarity) }
		guard !Task.isCancelled else { return .rejected(.cancelled) }
		guard let best else { return .rejected(.noEnrollment) }
		let matched = best.score >= embedder.matchThreshold
		if matched {
			let deny = denyChecked(sample, settlingExposure: settlingExposure)
			guard !Task.isCancelled else { return .rejected(.cancelled) }
			return Result(matched: true, score: best.score, face: faces[best.index],
				spoofDecision: deny.decision, matchedPrint: candidate,
				spoofConfidence: deny.confidence, didRunSpoofClassifier: deny.didRunClassifier)
		}
		// The mask path: the full face did not match, so try the upper face alone,
		// a little harder to pass than the full-face threshold. Only for faces
		// enrolled with upper prints, and never as the sole proof — the caller
		// keeps the movement challenge on for it.
		if allowsMaskUnlock, let upperMatcher, let upper = embedder.embedUpperFace(sample),
			let upperBest = try? upperMatcher.bestMatch(to: upper),
			upperBest.index < upperFaceIndices.count,
			upperBest.score >= embedder.matchThreshold + 0.05 {
			let deny = denyChecked(sample, settlingExposure: settlingExposure)
			guard !Task.isCancelled else { return .rejected(.cancelled) }
			return Result(matched: true, score: upperBest.score, face: faces[upperFaceIndices[upperBest.index]],
				spoofDecision: deny.decision, matchedPrint: upper, viaUpperFace: true,
				spoofConfidence: deny.confidence, didRunSpoofClassifier: deny.didRunClassifier)
		}
		guard !Task.isCancelled else { return .rejected(.cancelled) }
		return Result(matched: false, score: best.score, face: nil, spoofDecision: nil)
	}

	/// The classifier verdict plus the passive deny cues. The cues run only on frames
	/// the classifier already calls live, with anti-spoof always on, and can only turn
	/// a live frame into a spoof rejection — never the reverse.
	///
	/// When `settlingExposure` is true (the first ~450 ms after a cold camera wakes from
	/// sleep while auto-exposure ramps up), classifier flags still fail closed as `.suspect`
	/// (blocking match hold and unlock) without accumulating toward a lockout rejection.
	private func denyChecked(
		_ sample: FaceSample,
		settlingExposure: Bool
	) -> (decision: AntiSpoofGate.Decision?, confidence: Float?, didRunClassifier: Bool) {
		guard let antiSpoof else { return (nil, nil, false) }
		// Same 2.7x context crop the learned detector sees (224 px, the Spoof
		// model's input side); render once and share across classifier, bezel, and glare.
		let side = 224
		let sharedCrop: CVPixelBuffer?
		if antiSpoof.isActive && antiSpoof.usesSharedContextCrop224 {
			sharedCrop = makeContextCrop(sample, side)
			guard sharedCrop != nil else { return (.unavailable, nil, false) }
		} else {
			sharedCrop = nil
		}
		let (rawDecision, confidence) = antiSpoof.evaluate(sample, contextCrop: sharedCrop)
		let didRun = antiSpoof.isActive
		if case .spoof(_, let score) = rawDecision {
			if settlingExposure {
				return (.suspect(score: score), confidence, didRun)
			}
			classifierSpoofFrames += 1
			let decision: AntiSpoofGate.Decision = classifierSpoofFrames >= Self.classifierFireFrames ? rawDecision : .suspect(score: score)
			return (decision, confidence, didRun)
		}
		guard case .live = rawDecision else { return (rawDecision, confidence, didRun) }
		// An isolated suspect between live frames decays, so only a cluster of
		// suspect frames reaches `classifierFireFrames` and rejects.
		classifierSpoofFrames = max(0, classifierSpoofFrames - 1)
		guard let crop = sharedCrop ?? makeContextCrop(sample, side),
			let faceRect = FaceAligner.contextFaceRect(sample, side: side)
		else { return (rawDecision, confidence, didRun) }
		if bezelCue.record(frame: crop, faceRect: faceRect) {
			return (.spoof(
				reason: "device-bezel cue fired (face coverage \(bezelCue.level))",
				score: bezelCue.level), confidence, didRun)
		}
		if glareCue.record(frame: crop, faceRect: faceRect) {
			return (.spoof(
				reason: "glare cue fired (level \(glareCue.level))",
				score: glareCue.level), confidence, didRun)
		}
		return (rawDecision, confidence, didRun)
	}
}
