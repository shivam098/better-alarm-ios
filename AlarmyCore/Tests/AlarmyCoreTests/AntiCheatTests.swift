import XCTest
@testable import AlarmyCore

/// A mission that can be faked is not a mission. These tests cover the specific
/// ways a determined, half-asleep user tries to cheat.
final class AntiCheatTests: XCTestCase {

    // MARK: - Shake (PRD M-05)

    private func shake(_ t: TimeInterval, positive: Bool, rotation: Double = 1.0) -> MotionSample {
        MotionSample(timestamp: t, x: positive ? 3.0 : -3.0, y: 0, z: 0, rotationRate: rotation)
    }

    func testNaturalShakingIsCounted() {
        var counter = ShakeCounter()
        let timestamps: [TimeInterval] = [0.0, 0.31, 0.65, 1.02, 1.30]

        for (index, timestamp) in timestamps.enumerated() {
            _ = counter.consume(shake(timestamp, positive: index.isMultiple(of: 2)))
        }

        XCTAssertEqual(counter.count, 5)
        XCTAssertFalse(counter.mechanicalMotionDetected)
    }

    func testPushingInOneDirectionIsNotAShake() {
        var counter = ShakeCounter()
        for index in 0..<5 {
            _ = counter.consume(shake(Double(index) * 0.4, positive: true))
        }

        XCTAssertEqual(counter.count, 1, "A shake requires a direction reversal, not repeated lurches")
    }

    func testSlidingThePhoneWithoutRotationIsNotCounted() {
        var counter = ShakeCounter()
        for index in 0..<6 {
            _ = counter.consume(shake(Double(index) * 0.4, positive: index.isMultiple(of: 2), rotation: 0.05))
        }

        XCTAssertEqual(counter.count, 0, "Sliding the phone on a surface must not count")
    }

    func testGentleMovementBelowThresholdIsIgnored() {
        var counter = ShakeCounter()
        let outcome = counter.consume(
            MotionSample(timestamp: 0, x: 0.2, y: 0.1, z: 0.1, rotationRate: 1.0)
        )

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(counter.count, 0)
    }

    func testRapidRepeatsWithinTheRefractoryPeriodCountOnce() {
        var counter = ShakeCounter()
        _ = counter.consume(shake(0.00, positive: true))
        _ = counter.consume(shake(0.05, positive: false))
        _ = counter.consume(shake(0.09, positive: true))

        XCTAssertEqual(counter.count, 1, "One violent movement must not register as many shakes")
    }

    func testPerfectlyPeriodicMotionIsRejectedAsMechanical() {
        var counter = ShakeCounter()
        var sawRejection = false

        // A rig, or a phone taped to something oscillating, produces intervals a
        // human cannot reproduce.
        for index in 0..<12 {
            let outcome = counter.consume(
                shake(Double(index) * 0.3, positive: index.isMultiple(of: 2))
            )
            if outcome == .rejectedMechanical { sawRejection = true }
        }

        XCTAssertTrue(sawRejection, "Machine-perfect timing must be rejected")
        XCTAssertTrue(counter.mechanicalMotionDetected)
        XCTAssertLessThan(counter.count, 9, "Progress must be destroyed, not merely flagged")
    }

    func testResetClearsMechanicalSuspicion() {
        var counter = ShakeCounter()
        for index in 0..<12 {
            _ = counter.consume(shake(Double(index) * 0.3, positive: index.isMultiple(of: 2)))
        }
        counter.reset()

        XCTAssertEqual(counter.count, 0)
        XCTAssertFalse(counter.mechanicalMotionDetected)
    }

    // MARK: - Walking (PRD M-06, E29, E30)

    func testStepsBankedBeforeTheAlarmDoNotCount() {
        var validator = StepValidator(target: 30)

        // The user walked 5,000 steps yesterday. None of them may count.
        let outcome = validator.ingest(cumulativeSteps: 5000, at: 0, cadenceHz: 2.0)

        XCTAssertEqual(outcome, .baselineEstablished)
        XCTAssertEqual(validator.validatedSteps, 0)
        XCTAssertFalse(validator.isComplete)
    }

    func testGenuineWalkingIsCreditedUntilComplete() {
        var validator = StepValidator(target: 30)
        _ = validator.ingest(cumulativeSteps: 5000, at: 0, cadenceHz: 2.0)

        XCTAssertEqual(
            validator.ingest(cumulativeSteps: 5010, at: 10, cadenceHz: 2.0),
            .credited(steps: 10, total: 10)
        )
        XCTAssertEqual(validator.progress.label, "10/30 steps")

        _ = validator.ingest(cumulativeSteps: 5040, at: 25, cadenceHz: 2.0)
        XCTAssertTrue(validator.isComplete)
    }

    func testImplausibleStepBurstsAreRejected() {
        var validator = StepValidator(target: 50)
        _ = validator.ingest(cumulativeSteps: 0, at: 0, cadenceHz: 2.0)

        let outcome = validator.ingest(cumulativeSteps: 90, at: 1, cadenceHz: 2.0)

        guard case .rejected = outcome else {
            return XCTFail("90 steps in one second is not walking, got \(outcome)")
        }
        XCTAssertEqual(validator.validatedSteps, 0)
        XCTAssertEqual(validator.rejectedSamples, 1)
    }

    func testWavingThePhoneIsRejectedByCadenceCrossCheck() {
        var validator = StepValidator(target: 30)
        _ = validator.ingest(cumulativeSteps: 0, at: 0, cadenceHz: 2.0)

        // Plausible step count, but a cadence far outside human gait.
        let outcome = validator.ingest(cumulativeSteps: 10, at: 10, cadenceHz: 8.0)

        guard case .rejected = outcome else {
            return XCTFail("Hand-waving must not be credited, got \(outcome)")
        }
        XCTAssertEqual(validator.validatedSteps, 0)
    }

    func testPausingHoldsProgressRatherThanResettingIt() {
        var validator = StepValidator(target: 30)
        _ = validator.ingest(cumulativeSteps: 0, at: 0, cadenceHz: 2.0)
        _ = validator.ingest(cumulativeSteps: 12, at: 10, cadenceHz: 2.0)

        XCTAssertEqual(validator.ingest(cumulativeSteps: 12, at: 70, cadenceHz: nil), .noChange)
        XCTAssertEqual(validator.validatedSteps, 12, "A pause must never wipe earned progress")
    }

    // MARK: - Squats (PRD M-07)

    func testFullSquatIsCounted() {
        var counter = SquatRepCounter()

        _ = counter.consume(kneeAngleDegrees: 165, confidence: 0.9, at: 0.0)
        _ = counter.consume(kneeAngleDegrees: 130, confidence: 0.9, at: 0.3)
        _ = counter.consume(kneeAngleDegrees: 95, confidence: 0.9, at: 0.7)
        let outcome = counter.consume(kneeAngleDegrees: 165, confidence: 0.9, at: 1.2)

        XCTAssertEqual(outcome, .counted(total: 1))
    }

    func testPartialDipIsNotCounted() {
        var counter = SquatRepCounter()

        _ = counter.consume(kneeAngleDegrees: 165, confidence: 0.9, at: 0.0)
        _ = counter.consume(kneeAngleDegrees: 130, confidence: 0.9, at: 0.3)
        _ = counter.consume(kneeAngleDegrees: 165, confidence: 0.9, at: 0.8)

        XCTAssertEqual(counter.count, 0, "A shallow dip is not a squat")
    }

    func testBouncingTooFastIsNotCounted() {
        var counter = SquatRepCounter()

        _ = counter.consume(kneeAngleDegrees: 165, confidence: 0.9, at: 0.0)
        _ = counter.consume(kneeAngleDegrees: 130, confidence: 0.9, at: 0.1)
        _ = counter.consume(kneeAngleDegrees: 95, confidence: 0.9, at: 0.2)
        _ = counter.consume(kneeAngleDegrees: 165, confidence: 0.9, at: 0.5)

        XCTAssertEqual(counter.count, 0, "Bouncing must not be counted as repetitions")
    }

    func testLowConfidenceProducesCoachingRatherThanSilentFailure() {
        var counter = SquatRepCounter()
        let outcome = counter.consume(kneeAngleDegrees: 95, confidence: 0.2, at: 0.0)

        guard case .lowConfidence(let message) = outcome else {
            return XCTFail("Expected coaching, got \(outcome)")
        }
        XCTAssertFalse(message.isEmpty, "The user must be told why nothing is counting")
    }

    func testConsecutiveSquatsAccumulate() {
        var counter = SquatRepCounter()

        for rep in 0..<5 {
            let base = Double(rep) * 2.0
            _ = counter.consume(kneeAngleDegrees: 165, confidence: 0.9, at: base)
            _ = counter.consume(kneeAngleDegrees: 95, confidence: 0.9, at: base + 0.5)
            _ = counter.consume(kneeAngleDegrees: 165, confidence: 0.9, at: base + 1.4)
        }

        XCTAssertEqual(counter.count, 5)
        XCTAssertEqual(counter.progress(target: 10).label, "5/10 squats")
    }

    // MARK: - Permission fallbacks (PRD PRM-4, PRM-7)

    func testEveryMissionFallbackChainEndsSomewhereUsableWithoutPermissions() {
        for type in MissionType.allCases {
            let terminal = type.fallbackChain.last
            XCTAssertNotNil(terminal)
            XCTAssertTrue(
                terminal!.requiredPermissions.isEmpty,
                "\(type) must be able to fall back to a mission needing no permissions"
            )
        }
    }

    func testAlarmResolvesAFallbackWhenPermissionsAreDenied() {
        let alarm = Alarm(mission: MissionConfig(type: .squat))

        let fallback = alarm.resolvedFallback(excluding: [.camera, .motion, .motionFitness])

        XCTAssertTrue(fallback.requiredPermissions.isEmpty)
        XCTAssertNotEqual(fallback, .squat, "An alarm must never ring with a mission it cannot run")
    }

    func testExplicitFallbackIsHonouredWhenItIsUsable() {
        let alarm = Alarm(mission: MissionConfig(type: .photo), fallbackMission: .typing)
        XCTAssertEqual(alarm.resolvedFallback(excluding: [.camera]), .typing)
    }

    func testExplicitFallbackIsIgnoredWhenItAlsoNeedsADeniedPermission() {
        let alarm = Alarm(mission: MissionConfig(type: .photo), fallbackMission: .qr)
        let resolved = alarm.resolvedFallback(excluding: [.camera])

        XCTAssertNotEqual(resolved, .qr)
        XCTAssertTrue(resolved.requiredPermissions.isEmpty)
    }

    // MARK: - Configuration safety (PRD SAF-5)

    func testMissionTargetsAreClampedToSafeRanges() {
        let absurd = MissionConfig(type: .squat, difficulty: .veryHard, targetCount: 5000).normalized()
        XCTAssertEqual(absurd.targetCount, MissionConfig.targetRange(for: .squat).upperBound)

        let tooSmall = MissionConfig(type: .steps, targetCount: 0).normalized()
        XCTAssertEqual(tooSmall.targetCount, MissionConfig.targetRange(for: .steps).lowerBound)
    }

    func testEscalationIsCappedAtTheHardestDifficulty() {
        let config = MissionConfig(type: .math, difficulty: .veryHard)
        XCTAssertEqual(config.escalated().difficulty, .veryHard)
    }

    func testCombinationMissionUnionsItsChildrenPermissions() {
        let combination = MissionConfig(
            type: .combination,
            children: [MissionConfig(type: .math), MissionConfig(type: .qr), MissionConfig(type: .steps)]
        )

        XCTAssertEqual(combination.requiredPermissions, [.camera, .motionFitness])
    }

    func testEveryMissionInTheLibraryIsAvailable() {
        // The product promise: no mission is visible-but-locked (PRD MON-2).
        XCTAssertEqual(MissionLibrary.all.count, MissionType.allCases.count)
        for type in MissionType.allCases {
            XCTAssertEqual(MissionLibrary.descriptor(for: type).type, type)
        }
    }
}
