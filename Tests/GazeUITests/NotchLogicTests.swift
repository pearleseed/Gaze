import AppKit
import GazeDesign
@testable import GazeLockScreen
import SwiftUI
import Testing

@Suite("Notch Panel Alignment, Companion Motion & Seam Geometry")
@MainActor
struct NotchLogicTests {
	@Test func hoverZoneCoversTheNotchAndItsTopEdge() {
		let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
		let zone = NotchMetrics.hoverZone(screenFrame: screen, cutoutWidth: 185, notchHeight: 38)
		#expect(zone.maxY == screen.maxY)
		#expect(abs(zone.midX - screen.midX) < 0.001)
		#expect(zone.width >= 185 * 1.56)
		#expect(zone.height > 38)
		// The pointer pressed against the top edge, right under the camera.
		#expect(NotchMetrics.zone(zone, includes: CGPoint(x: screen.midX, y: screen.maxY)))
		#expect(NotchMetrics.zone(zone, includes: CGPoint(x: screen.midX + 140, y: screen.maxY - 30)))
		#expect(!NotchMetrics.zone(zone, includes: CGPoint(x: 40, y: screen.maxY)))
		#expect(!NotchMetrics.zone(zone, includes: CGPoint(x: screen.midX, y: screen.midY)))

		// No notch: the same band still sits at the top centre, on any screen origin.
		let external = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
		let plain = NotchMetrics.hoverZone(screenFrame: external, cutoutWidth: nil, notchHeight: 0)
		#expect(plain.maxY == external.maxY)
		#expect(abs(plain.midX - external.midX) < 0.001)
		#expect(plain.height >= 24)
	}

	@Test func panelAlignmentOutwardPixelRounding() {
		let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
		let actual = NotchMetrics.panelFrame(
			size: CGSize(width: 179 * 1.56, height: 98 - 0.001003440366972086),
			screenFrame: screen,
			scale: 2
		)
		#expect(actual == CGRect(x: 595, y: 858, width: 280, height: 98))

		var cases = 0
		for scale: CGFloat in [1, 2] {
			for candidateScreen in [
				screen,
				CGRect(x: -1920, y: -200, width: 1920, height: 1080),
				CGRect(x: 1470, y: 140, width: 1512.5, height: 982),
			] {
				for width: CGFloat in [179, 239.24, 279.24, 319.24] {
					for height: CGFloat in [32, 77.999, 98, 128.25, 256.4] {
						let desired = CGSize(width: width, height: height)
						let aligned = NotchMetrics.panelFrame(size: desired, screenFrame: candidateScreen, scale: scale)
						#expect(aligned.width >= width && aligned.height >= height)
						#expect((aligned.width - width) * scale < 2.000001)
						#expect((aligned.height - height) * scale < 1.000001)
						#expect(aligned.maxY == candidateScreen.maxY)
						#expect(abs(aligned.midX - candidateScreen.midX) * scale <= 0.5)
						for edge in [
							(aligned.minX - candidateScreen.minX) * scale,
							(aligned.maxX - candidateScreen.minX) * scale,
							aligned.height * scale,
						] {
							#expect(abs(edge - edge.rounded()) < 0.000001)
						}
						cases += 1
					}
				}
			}
		}
		#expect(cases == 2 * 3 * 4 * 5)
	}

	@Test func companionMotionMappingsContinuityAndPlaybackRetargeting() {
		let actions: [(NotchCapsuleModel.Phase, GazeFaceMotion)] = [
			(.challenge(prompt: "Turn your head left", symbol: "arrowshape.left.fill", hintX: -1, hintY: 0, pulses: false), .turnLeft),
			(.challenge(prompt: "Turn your head right", symbol: "arrowshape.right.fill", hintX: 1, hintY: 0, pulses: false), .turnRight),
			(.challenge(prompt: "Nod your head", symbol: "arrowshape.down.fill", hintX: 0, hintY: 1, pulses: false), .nod),
			(.challenge(prompt: "Blink", symbol: "eye.fill", hintX: 0, hintY: 0, pulses: true), .blink),
			(.challenge(prompt: "Open your mouth", symbol: "mouth.fill", hintX: 0, hintY: 0, pulses: true), .openMouth),
		]

		for (phase, expected) in actions {
			#expect(GazeFaceMotion(phase: phase) == expected)
		}
		#expect(
			GazeFaceMotion(
				phase: .challenge(prompt: "Look at the camera", symbol: "camera.fill", hintX: 0, hintY: 0, pulses: false)
			) == .resting
		)
		#expect(GazeFaceMotion(phase: .success) == .accepted)
		#expect(GazeFaceMotion(phase: .spoofRejected) == .rejected)

		for frame in 0...336 {
			let time = Double(frame) / 120
			let left = GazeFaceMotion.turnLeft.pose(at: time)
			let right = GazeFaceMotion.turnRight.pose(at: time)
			#expect(left.turn <= 0 && right.turn >= 0)
			#expect(abs(left.turn + right.turn) < 0.000001)
			for (_, motion) in actions {
				let current = motion.pose(at: time)
				let next = motion.pose(at: time + 1 / 120.0)
				#expect(abs(current.turn - next.turn) < 0.04)
				#expect(abs(current.nod - next.nod) < 0.04)
				#expect(abs(current.eyesOpen - next.eyesOpen) < 0.12)
				#expect(abs(current.mouthOpen - next.mouthOpen) < 0.04)
			}
		}

		for motion in [GazeFaceMotion.turnLeft, .turnRight] {
			let radians = abs(motion.pose(at: 1.2).turn) * 0.489
			#expect(radians > 0.30 && radians < 0.38)
		}
		#expect(GazeFaceMotion.blink.pose(at: 0.95).eyesOpen < 0.1)
		#expect(GazeFaceMotion.openMouth.pose(at: 1.2).mouthOpen == 1)
		#expect(GazeFaceMotion.nod.pose(at: 2.79).nod == 0)

		// Accepted / rejected settle and resting / scanning loop smoothly.
		#expect(GazeFaceMotion.accepted.pose(at: 0.18).nod > 0.4)
		#expect(GazeFaceMotion.accepted.pose(at: 0.45) == GazeFaceMotion.accepted.stillPose)
		#expect(GazeFaceMotion.rejected.pose(at: 0.15).turn > 0)
		#expect(GazeFaceMotion.rejected.pose(at: 0.28).turn < 0)
		for time in [0.9, 2.8, 10.0, 100.0] {
			#expect(GazeFaceMotion.accepted.pose(at: time) == GazeFaceMotion.accepted.stillPose)
			#expect(GazeFaceMotion.rejected.pose(at: time) == GazeFaceMotion.rejected.stillPose)
		}

		for motion in [GazeFaceMotion.resting, .scanning] {
			for frame in 0...960 {
				let idle = motion.pose(at: Double(frame) / 120)
				#expect(idle.eyesOpen == 1 && abs(idle.turn) <= 0.18 && idle.gaze == 0 && idle.nod == 0 && idle.breath == 0)
			}
			#expect(motion.pose(at: 1.7).turn > 0)
			#expect(motion.pose(at: 5.7).turn < 0)
			#expect(motion.pose(at: 8) == motion.pose(at: 0))
			#expect(motion.stillPose == GazeFacePose())
		}

		var playback = GazeFacePlayback(motion: .turnRight, at: 0)
		for (time, motion) in [
			(1.2, GazeFaceMotion.accepted),
			(1.23, .rejected),
			(1.27, .turnLeft),
			(1.32, .scanning),
		] {
			let before = playback.pose(at: time)
			playback.retarget(to: motion, at: time)
			#expect(playback.pose(at: time) == before)
			let settledTime = time + 0.2
			#expect(playback.pose(at: settledTime) == motion.pose(at: settledTime - time))
		}

		for motion in [GazeFaceMotion.accepted, .rejected, .scanning] {
			for frame in 0..<1200 {
				let time = Double(frame) / 120
				let current = motion.pose(at: time)
				let next = motion.pose(at: time + 1 / 120.0)
				#expect(abs(current.turn - next.turn) < 0.08)
				#expect(abs(current.nod - next.nod) < 0.08)
				#expect(abs(current.expression - next.expression) < 0.14)
				#expect(abs(current.eyesOpen - next.eyesOpen) < 0.14)
			}
		}
	}

	@Test func notchPanelShapeSeamContainsFlareJoinPoints() {
		var samples = 0
		for width: CGFloat in [200, 281.5, 346] {
			for height: CGFloat in [35, 64.5, 128] {
				for radius: CGFloat in [0, 4.25, 17] {
					let rect = CGRect(x: 3.25, y: 2.5, width: width, height: height)
					let path = NotchPanelShape(topRadius: radius, bottomRadius: 26).path(in: rect)
					for inset: CGFloat in [0.1, 0.5, 0.9, 1.5] {
						for offset: CGFloat in [0.1, 0.5, 1, 2, 4] {
							for edge in [rect.minX + radius + inset, rect.maxX - radius - inset] {
								#expect(path.contains(CGPoint(x: edge, y: rect.minY + offset)))
								samples += 1
							}
						}
					}
				}
			}
		}
		#expect(samples == 3 * 3 * 3 * 4 * 5 * 2)
	}

	@Test func connectedPanelAnimationMatchesGlanceScaleAndFitsCaptions() {
		#expect(ConnectedMetrics.dropHeight == ConnectedMetrics.baseDropHeight + ConnectedMetrics.challengeRoom)
		let notchInset: CGFloat = 32
		let defaultHeight = notchInset + ConnectedMetrics.dropHeight
		#expect(defaultHeight == 200)

		let model = NotchCapsuleModel()
		model.shape = .attached
		model.glyphPlacement = .centred
		model.phase = .scanning
		model.isExpanded = true

		let capsule = NotchCapsule(
			model: model, width: 278, height: defaultHeight,
			notchInset: notchInset, cutoutWidth: 180, hasNotch: true)
		let nativeVideoSide = capsule.glyphSide * 1.30
		#expect(nativeVideoSide >= 140 && nativeVideoSide <= 148)
		#expect(capsule.glyphTop > notchInset + 8)
		#expect(capsule.glyphTop + capsule.glyphSide + 30 < defaultHeight)

		let compact = NotchCapsule(
			model: model, width: 238, height: defaultHeight - 20,
			notchInset: notchInset, cutoutWidth: 180, hasNotch: true)
		#expect(compact.glyphTop > notchInset + 6)
		#expect(compact.glyphTop + compact.glyphSide + 30 < defaultHeight - 20)
	}
}
