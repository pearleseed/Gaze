import CoreGraphics

/// How far away Gaze can recognise a face.
///
/// Close needs the face to fill more of the frame; far accepts a smaller
/// face and asks for a slightly closer match, since distant faces give noisier prints.
package enum DetectionDistance: String, CaseIterable, Sendable {
	case close
	case standard
	case far

	/// Smallest face height, as a fraction of frame height, worth identifying.
	package var minFaceHeight: CGFloat {
		switch self {
		case .close: return 0.20
		case .standard: return 0.14
		case .far: return 0.10
		}
	}

	/// Added to the embedder's match threshold alongside the sensitivity offset.
	package var thresholdOffset: Float {
		switch self {
		case .close: return 0
		case .standard: return 0
		case .far: return 0.03
		}
	}

	package var title: String {
		switch self {
		case .close: return "Close"
		case .standard: return "Default"
		case .far: return "Far"
		}
	}
}
