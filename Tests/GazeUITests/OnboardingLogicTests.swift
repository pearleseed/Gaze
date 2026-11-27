import AVFoundation
import CoreGraphics
import Foundation
import GazeDesign
import SwiftUI
import Testing
@testable import GazeApp

@Suite("Onboarding Flow, Tour Plans, Requests & Companion Lessons", .serialized)
@MainActor
struct OnboardingLogicTests {
	@Test func setupPlanInclusionAndTraversal() {
		for hasPassword in [false, true] {
			for hasPermission in [false, true] {
				for forced in [nil] + SetupStep.allCases.map(Optional.some) {
					let plan = SetupPlan(hasPassword: hasPassword, hasPermission: hasPermission, including: forced)
					#expect(plan.steps.prefix(3) == [.how, .meetGaze, .capture])
					#expect(plan.steps.contains(.password) == (!hasPassword || forced == .password))
					#expect(plan.steps.contains(.permission) == (!hasPermission || forced == .permission))

					var traversed: [SetupStep] = []
					var current = SetupStep.welcome
					while let next = plan.next(after: current) {
						#expect(next.rawValue > current.rawValue)
						traversed.append(next)
						current = next
					}
					#expect(traversed == plan.steps + [.done])
					#expect(plan.previous(before: .how) == .welcome)
					#expect(plan.previous(before: .meetGaze) == .how)
					#expect(plan.previous(before: .capture) == .meetGaze)
					#expect(plan.previous(before: .password) == .capture)
					#expect(plan.previous(before: .permission) == (plan.steps.contains(.password) ? .password : .capture))

					let addFace = SetupPlan(
						hasPassword: hasPassword,
						hasPermission: hasPermission,
						including: forced,
						purpose: .addFace
					)
					#expect(addFace.steps == [.capture])
					#expect(addFace.next(after: .capture) == .done)
					#expect(addFace.next(after: .done) == nil)
					for step in SetupStep.allCases {
						#expect(addFace.previous(before: step) == nil)
					}
				}
			}
		}

		let unenrolled = SetupPlan(hasPassword: false, hasPermission: false, hasEnrollment: false)
		#expect(unenrolled.steps.prefix(3) == [.how, .meetGaze, .capture])

		let enrolled = SetupPlan(hasPassword: false, hasPermission: false, hasEnrollment: true)
		#expect(enrolled.steps.prefix(2) == [.how, .meetGaze])
		#expect(!enrolled.steps.contains(.capture))

		let enrolledForced = SetupPlan(
			hasPassword: false,
			hasPermission: false,
			including: .capture,
			hasEnrollment: true
		)
		#expect(enrolledForced.steps.contains(.capture))

		let enrolledAddFace = SetupPlan(
			hasPassword: false,
			hasPermission: false,
			purpose: .addFace,
			hasEnrollment: true
		)
		#expect(enrolledAddFace.steps == [.capture])
	}

	@Test func welcomeTourRoutingForcedStepsAndAddFaceIsolation() {
		for hasPassword in [false, true] {
			for hasPermission in [false, true] {
				for hasEnrollment in [false, true] {
					let tour = SetupPlan(
						hasPassword: hasPassword,
						hasPermission: hasPermission,
						hasEnrollment: hasEnrollment,
						usesWelcomeTour: true
					)
					#expect(!tour.steps.contains(.how) && !tour.steps.contains(.meetGaze))
					#expect(tour.steps.contains(.capture) == !hasEnrollment)
					#expect(tour.steps.contains(.password) == !hasPassword)
					#expect(tour.steps.contains(.permission) == !hasPermission)
					#expect(tour.next(after: .welcome) == (tour.steps.first ?? .done))
					#expect(tour.previous(before: .capture) == .welcome)

					var traversed: [SetupStep] = []
					var current = SetupStep.welcome
					while let next = tour.next(after: current) {
						#expect(next.rawValue > current.rawValue)
						traversed.append(next)
						current = next
					}
					#expect(traversed == tour.steps + [.done])
				}
			}
		}

		let tour = SetupPlan(hasPassword: false, hasPermission: false, hasEnrollment: false, usesWelcomeTour: true)
		#expect(tour.steps == [.capture, .password, .permission])
		#expect(tour.next(after: .welcome) == .capture)
		#expect(tour.previous(before: .capture) == .welcome)
		#expect(tour.previous(before: .password) == .capture)
		#expect(tour.previous(before: .permission) == .password)

		let tourEnrolled = SetupPlan(
			hasPassword: false,
			hasPermission: false,
			hasEnrollment: true,
			usesWelcomeTour: true
		)
		#expect(tourEnrolled.steps == [.password, .permission])
		#expect(tourEnrolled.next(after: .welcome) == .password)

		let tourConfigured = SetupPlan(
			hasPassword: true,
			hasPermission: true,
			hasEnrollment: true,
			usesWelcomeTour: true
		)
		#expect(tourConfigured.steps.isEmpty)
		#expect(tourConfigured.next(after: .welcome) == .done)

		let tourForcedHow = SetupPlan(
			hasPassword: false,
			hasPermission: false,
			including: .how,
			hasEnrollment: false,
			usesWelcomeTour: true
		)
		#expect(tourForcedHow.steps == [.how, .capture, .password, .permission])
		#expect(tourForcedHow.next(after: .welcome) == .how)
		#expect(tourForcedHow.previous(before: .how) == .welcome)
		#expect(tourForcedHow.previous(before: .capture) == .how)

		let tourForcedMeetGaze = SetupPlan(
			hasPassword: false,
			hasPermission: false,
			including: .meetGaze,
			hasEnrollment: false,
			usesWelcomeTour: true
		)
		#expect(tourForcedMeetGaze.steps == [.meetGaze, .capture, .password, .permission])
		#expect(tourForcedMeetGaze.next(after: .welcome) == .meetGaze)
		#expect(tourForcedMeetGaze.previous(before: .meetGaze) == .welcome)
		#expect(tourForcedMeetGaze.previous(before: .capture) == .meetGaze)

		let legacy = SetupPlan(hasPassword: false, hasPermission: false, hasEnrollment: false, usesWelcomeTour: false)
		#expect(legacy.steps == [.how, .meetGaze, .capture, .password, .permission])
		#expect(legacy.next(after: .welcome) == .how)
		#expect(legacy.previous(before: .meetGaze) == .how)
		#expect(legacy.previous(before: .capture) == .meetGaze)

		let tourAddFace = SetupPlan(
			hasPassword: false,
			hasPermission: false,
			purpose: .addFace,
			hasEnrollment: true,
			usesWelcomeTour: true
		)
		#expect(tourAddFace.steps == [.capture])
		#expect(tourAddFace.next(after: .capture) == .done)
		for step in SetupStep.allCases {
			#expect(tourAddFace.previous(before: step) == nil)
		}
	}

	@Test func onboardingHistoryAndSetupRequestRouting() throws {
		let suite = "com.pearleseed.OnboardingTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(OnboardingHistory.needsIntroduction(isEnrolled: false, defaults: defaults))
		#expect(!OnboardingHistory.needsIntroduction(isEnrolled: true, defaults: defaults))
		#expect(OnboardingHistory.presentsSetup(isEnrolled: false, arguments: [], defaults: defaults))
		for arguments in [["--agent"], ["--settings"], ["--agent", "--setup"]] {
			#expect(!OnboardingHistory.presentsSetup(isEnrolled: false, arguments: arguments, defaults: defaults))
		}

		OnboardingHistory.markPresented(defaults: defaults)
		for enrolled in [false, true] {
			#expect(!OnboardingHistory.presentsSetup(isEnrolled: enrolled, arguments: [], defaults: defaults))
			for arguments in [["--setup"], ["--capture-dataset"], ["--setup-step=meetGaze"]] {
				#expect(OnboardingHistory.presentsSetup(isEnrolled: enrolled, arguments: arguments, defaults: defaults))
			}
		}
		let reloaded = try #require(UserDefaults(suiteName: suite))
		#expect(!OnboardingHistory.needsIntroduction(isEnrolled: false, defaults: reloaded))

		// Request routing.
		let revision = SetupRequest.presentation.revision
		SetupRequest.begin()
		#expect(SetupRequest.presentation.purpose == .addFace)
		#expect(SetupRequest.consumePendingStep() == .capture)
		#expect(SetupRequest.consumePendingStep() == .capture)

		SetupRequest.beginOnboarding()
		#expect(SetupRequest.presentation.purpose == .onboarding)
		#expect(SetupRequest.consumePendingStep() == .welcome)
		#expect(SetupRequest.presentation.revision == revision + 2)

		for step in SetupStep.allCases {
			SetupRequest.begin(at: step)
			#expect(SetupRequest.consumePendingStep() == step)
			#expect(SetupRequest.presentation.purpose == (step == .capture ? .addFace : .onboarding))
		}
	}

	@Test func permissionsCompletionAndShakeInterpolation() {
		for accessibility in [false, true] {
			for keyboardEvents in [false, true] {
				#expect(
					SetupPermissionStatus(accessibility: accessibility, keyboardEvents: keyboardEvents).isReady
						== (accessibility && keyboardEvents)
				)
				let unfinished = SetupUnfinished(
					needsPassword: !accessibility,
					needsAccessibility: !keyboardEvents
				)
				#expect(unfinished.isComplete == (accessibility && keyboardEvents))
			}
		}

		#expect(SetupCameraAccessContent.actionTitle(for: .notDetermined) == "Allow Camera Access")
		#expect(SetupCameraAccessContent.actionTitle(for: .denied) == "Open Camera Settings")
		#expect(SetupCameraAccessContent.actionTitle(for: .restricted) == nil)
		#expect(SetupCameraAccessContent.actionTitle(for: .authorized) == nil)

		for failed in [false, true] {
			for needsPassword in [false, true] {
				for needsAccessibility in [false, true] {
					for addingFace in [false, true] {
						let unfinished = SetupUnfinished(
							needsPassword: needsPassword,
							needsAccessibility: needsAccessibility
						)
						let title = SetupDoneStep.title(
							failed: failed,
							unfinished: unfinished,
							isAddingFace: addingFace
						)
						#expect((title == "Enjoy a little less typing.") == (!failed && !addingFace && unfinished.isComplete))
						#expect((title == "Face added") == (!failed && addingFace))
						let offersSettings = SetupDoneStep.showsFinishInSettings(
							failed: failed,
							unfinished: unfinished,
							isAddingFace: addingFace,
							canOpenSettings: true
						)
						#expect(offersSettings == (!failed && !addingFace && !unfinished.isComplete))
						#expect(
							!SetupDoneStep.showsFinishInSettings(
								failed: failed,
								unfinished: unfinished,
								isAddingFace: addingFace,
								canOpenSettings: false
							)
						)
					}
				}
			}
		}

		var shake = ShakeEffect(travel: 1)
		for endpoint in [CGFloat(0), 1, 2] {
			shake.animatableData = endpoint
			#expect(abs(shake.effectValue(size: CGSize(width: 100, height: 40)).m31) < 0.001)
		}
		shake.animatableData = 0.25
		#expect(abs(shake.animatableData - 0.25) < 0.001)
		let outward = shake.effectValue(size: CGSize(width: 100, height: 40)).m31
		shake.animatableData = 0.5
		let returning = shake.effectValue(size: CGSize(width: 100, height: 40)).m31
		#expect(outward > 1 && returning < -1)
		shake.isEnabled = false
		#expect(abs(shake.effectValue(size: CGSize(width: 100, height: 40)).m31) < 0.001)
	}

	@Test func expressionsPeekCuriosityAndLessonPlaybackContinuity() throws {
		#expect(GazeExpressionLesson.scanning.explanation(movementCount: 1).contains("one short movement."))
		#expect(GazeExpressionLesson.scanning.explanation(movementCount: 2).contains("two short movements."))

		let motions: [GazeFaceMotion] = [
			.resting, .scanning, .turnLeft, .turnRight, .nod, .blink, .openMouth, .resting, .accepted, .rejected,
		]
		#expect(GazeExpressionLesson.allCases.map(\.motion) == motions)
		#expect(GazeExpressionLesson.waiting.previous == nil)
		#expect(GazeExpressionLesson.retry.next == nil)
		for lesson in GazeExpressionLesson.allCases {
			if let next = lesson.next {
				#expect(next.previous == lesson)
			}
		}

		for time in stride(from: 0.0, through: 40.0, by: 1.0 / 120) {
			let sample = GazePeekSample.at(time)
			#expect(sample.reveal.isFinite && (0...1).contains(sample.reveal))
			#expect(sample.pose.face.eyesOpen == 1)
			#expect(sample.pose.face.turn.isFinite && sample.pose.face.gaze.isFinite)
			let next = GazePeekSample.at(time + 1.0 / 120)
			#expect(abs(sample.reveal - next.reveal) < 0.02)
			if time > 1.4 {
				#expect(sample.reveal == 1)
			}
		}
		#expect(GazePeekSample.at(2.8).reveal == 1)
		#expect(GazePeekSample.at(12.8).reveal == 1)

		#expect(GazeCuriosityMotion.pose(at: 1.5).face.gaze > 0)
		#expect(GazeCuriosityMotion.pose(at: 1.5).face.turn == 0)
		#expect(GazeCuriosityMotion.pose(at: 1.5).drift == 0)
		#expect(GazeCuriosityMotion.pose(at: 3.2).drift > 0)
		for time in [0.0, 7.0, 8.0, 12.9, GazeCuriosityMotion.duration, GazeCuriosityMotion.duration + 0.5] {
			#expect(GazeCuriosityMotion.pose(at: time) == GazeCompanionPose())
		}
		for frame in 0..<2160 {
			let pose = GazeCuriosityMotion.pose(at: Double(frame) / 120)
			let next = GazeCuriosityMotion.pose(at: Double(frame + 1) / 120)
			#expect(abs(pose.drift - next.drift) < 0.004)
			#expect(abs(pose.face.gaze - next.face.gaze) < 0.01)
			#expect(abs(pose.face.turn - next.face.turn) < 0.01)
			#expect(pose.face.eyesOpen == 1 && pose.face.expression == 0 && pose.face.nod == 0)
		}

		for motion in GazeExpressionLesson.allCases.map(\.motion) {
			var playback = GazeLessonPlayback(motion: motion, at: 0)
			let before = playback.pose(at: 0.75)
			playback.setPaused(true, at: 0.75)
			#expect(playback.pose(at: 10) == before)
			playback.setPaused(false, at: 10)
			#expect(playback.pose(at: 10) == before)
			let current = playback.pose(at: 10.1)
			playback.select(.nod, at: 10.1)
			#expect(playback.pose(at: 10.1) == current)
		}

		for motion in [GazeFaceMotion.accepted, .rejected] {
			let playback = GazeLessonPlayback(motion: motion, at: 0)
			let duration = try #require(GazeCompanionPresentation.standard.duration(for: motion))
			let period = duration + 1
			let before = playback.pose(at: period - 0.0001)
			let after = playback.pose(at: period + 0.0001)
			#expect(abs(before.face.expression - after.face.expression) < 0.01)
			#expect(abs(before.face.nod - after.face.nod) < 0.01)
			#expect(abs(before.face.turn - after.face.turn) < 0.01)
		}
	}
}
