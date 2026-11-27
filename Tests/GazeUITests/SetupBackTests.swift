import Foundation
import Testing
@testable import GazeApp

@Suite("Setup Back Navigation Invariants")
struct SetupBackTests {
	private func backChain(_ plan: SetupPlan, from step: SetupStep) -> [SetupStep] {
		var chain: [SetupStep] = []
		var current: SetupStep? = step
		var guardCount = 0
		while let step = current, guardCount < 16 {
			guardCount += 1
			guard let prev = plan.previous(before: step) else { break }
			chain.append(prev)
			current = prev
		}
		return chain
	}

	private func forwardChain(_ plan: SetupPlan) -> [SetupStep] {
		var traversed: [SetupStep] = []
		var current = SetupStep.welcome
		var guardCount = 0
		while let next = plan.next(after: current), guardCount < 16 {
			guardCount += 1
			#expect(next.rawValue > current.rawValue)
			traversed.append(next)
			current = next
		}
		return traversed
	}

	@Test func exhaustivePlanCombinationsAndAddFaceIsolation() {
		let forcedOptions: [SetupStep?] = [nil] + SetupStep.allCases.map { Optional($0) }
		var combinations = 0
		for hasPassword in [false, true] {
			for hasPermission in [false, true] {
				for hasEnrollment in [false, true] {
					for tour in [false, true] {
						for forced in forcedOptions {
							combinations += 1
							let plan = SetupPlan(
								hasPassword: hasPassword,
								hasPermission: hasPermission,
								including: forced,
								hasEnrollment: hasEnrollment,
								usesWelcomeTour: tour
							)

							let expectHow = !tour || forced == .how
							let expectMeetGaze = !tour || forced == .meetGaze
							let expectCapture = !hasEnrollment || forced == .capture
							let expectPassword = !hasPassword || forced == .password
							let expectPermission = !hasPermission || forced == .permission

							#expect(plan.steps.contains(.how) == expectHow)
							#expect(plan.steps.contains(.meetGaze) == expectMeetGaze)
							#expect(plan.steps.contains(.capture) == expectCapture)
							#expect(plan.steps.contains(.password) == expectPassword)
							#expect(plan.steps.contains(.permission) == expectPermission)
							#expect(forwardChain(plan) == plan.steps + [.done])

							let intro: SetupStep = plan.steps.contains(.meetGaze)
								? .meetGaze
								: (plan.steps.contains(.how) ? .how : .welcome)
							let beforePassword: SetupStep = plan.steps.contains(.capture) ? .capture : intro
							if plan.steps.contains(.password) {
								#expect(plan.previous(before: .password) == beforePassword)
							}
							if plan.steps.contains(.permission) {
								let expected = plan.steps.contains(.password) ? SetupStep.password : beforePassword
								#expect(plan.previous(before: .permission) == expected)
								#expect(backChain(plan, from: .permission).contains(.welcome))
							}
							if plan.steps.contains(.capture) {
								#expect(plan.previous(before: .capture) != nil)
							}

							let addFace = SetupPlan(
								hasPassword: hasPassword,
								hasPermission: hasPermission,
								including: forced,
								purpose: .addFace,
								hasEnrollment: hasEnrollment,
								usesWelcomeTour: tour
							)
							#expect(addFace.steps == [.capture])
							#expect(addFace.next(after: .capture) == .done)
							for step in SetupStep.allCases {
								#expect(addFace.previous(before: step) == nil)
							}
						}
					}
				}
			}
		}
		#expect(combinations == 2 * 2 * 2 * 2 * 8)
	}

	@Test func namedSpotChecksPinBackRouting() {
		let legacy = SetupPlan(hasPassword: false, hasPermission: false, hasEnrollment: false, usesWelcomeTour: false)
		#expect(legacy.steps == [.how, .meetGaze, .capture, .password, .permission])
		#expect(legacy.previous(before: .password) == .capture)
		#expect(legacy.previous(before: .permission) == .password)
		#expect(legacy.previous(before: .capture) == .meetGaze)

		let tourFresh = SetupPlan(hasPassword: false, hasPermission: false, hasEnrollment: false, usesWelcomeTour: true)
		#expect(tourFresh.steps == [.capture, .password, .permission])
		#expect(tourFresh.previous(before: .password) == .capture)
		#expect(tourFresh.previous(before: .permission) == .password)
		#expect(tourFresh.previous(before: .capture) == .welcome)

		let tourEnrolled = SetupPlan(hasPassword: false, hasPermission: false, hasEnrollment: true, usesWelcomeTour: true)
		#expect(tourEnrolled.steps == [.password, .permission])
		#expect(tourEnrolled.previous(before: .password) == .welcome)
		#expect(tourEnrolled.previous(before: .permission) == .password)

		let enrolledLegacy = SetupPlan(hasPassword: false, hasPermission: true, hasEnrollment: true, usesWelcomeTour: false)
		#expect(!enrolledLegacy.steps.contains(.capture))
		#expect(enrolledLegacy.previous(before: .password) == .meetGaze)

		let passwordOnly = SetupPlan(hasPassword: false, hasPermission: true, hasEnrollment: false, usesWelcomeTour: true)
		#expect(passwordOnly.steps == [.capture, .password])
		#expect(passwordOnly.previous(before: .password) == .capture)

		let permissionOnly = SetupPlan(hasPassword: true, hasPermission: false, hasEnrollment: false, usesWelcomeTour: true)
		#expect(permissionOnly.steps == [.capture, .permission])
		#expect(permissionOnly.previous(before: .permission) == .capture)
	}
}
