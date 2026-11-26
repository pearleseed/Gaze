import Foundation
import Vision

extension LivenessChallenge {

	// MARK: - Landmark measurements

	/// Average eye openness — the eye landmark box's height over its width. ~0.30 open, dips
	/// below ~0.14 on a blink.
	package static func eyeOpenness(_ lm: VNFaceLandmarks2D) -> Float? {
		func openness(_ region: VNFaceLandmarkRegion2D?) -> Float? {
			guard let p = region?.normalizedPoints, p.count >= 4 else { return nil }
			let xs = p.map(\.x), ys = p.map(\.y)
			guard let minX = xs.min(), let maxX = xs.max(),
				let minY = ys.min(), let maxY = ys.max(), maxX - minX > 0.0001
			else { return nil }
			return Float((maxY - minY) / (maxX - minX))
		}
		guard let left = openness(lm.leftEye), let right = openness(lm.rightEye) else { return nil }
		return max(left, right)
	}

	/// Pupil shift within the eye, as a fraction of eye width: (pupil.x - eyeCentre.x)
	/// / eyeWidth per eye, averaged across the usable eyes. Positive means the pupils
	/// sit toward +x in landmark space, which reads as the person's own left — the
	/// same polarity as yaw, where a leftward turn increases the angle.
	package static func gazeOffset(_ landmarks: VNFaceLandmarks2D?) -> Double? {
		func shift(eye: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?) -> Double? {
			guard let outline = eye?.normalizedPoints, outline.count >= 2,
				let dots = pupil?.normalizedPoints, !dots.isEmpty else { return nil }
			let xs = outline.map(\.x)
			guard let minX = xs.min(), let maxX = xs.max(), maxX - minX >= 1e-3 else { return nil }
			let pupilX = dots.map(\.x).reduce(0, +) / Double(dots.count)
			return (pupilX - (minX + maxX) / 2) / (maxX - minX)
		}
		let shifts = [shift(eye: landmarks?.leftEye, pupil: landmarks?.leftPupil),
			shift(eye: landmarks?.rightEye, pupil: landmarks?.rightPupil)].compactMap { $0 }
		guard !shifts.isEmpty else { return nil }
		return shifts.reduce(0, +) / Double(shifts.count)
	}

	/// Mouth openness — the inner-lip box's height over the mouth's width. Near 0 closed,
	/// well above 0.3 with the mouth open. Normalised by mouth width so it's scale-free.
	package static func mouthOpenness(_ lm: VNFaceLandmarks2D) -> Float? {
		guard let p = lm.innerLips?.normalizedPoints, p.count >= 4 else { return nil }
		let xs = p.map(\.x), ys = p.map(\.y)
		guard let minX = xs.min(), let maxX = xs.max(),
			let minY = ys.min(), let maxY = ys.max(), maxX - minX > 0.0001
		else { return nil }
		return Float((maxY - minY) / (maxX - minX))
	}
}
