import XCTest
@testable import AlarmyCore

/// These tests encode the promises the product is built on. If any of them
/// fail, the app is lying to its users about waking them up.
final class AlarmStateMachineTests: XCTestCase {

    func testMissionRequestedForSnoozeSchedulesSnoozeRatherThanCompleting() {
        let context = AlarmStateContext(
            snooze: SnoozeSettings(costsMission: true), snoozeCount: 1,
            missionSatisfied: true, snoozeAfterMission: true
        )
        let result = AlarmStateMachine.reduce(state: .missionActive, event: .missionCompleted, context: context)
        XCTAssertEqual(result.state, .snoozed)
        XCTAssertTrue(result.effects.contains(.scheduleSnooze(minutes: 9)))
        XCTAssertFalse(result.effects.contains(.cancelWatchdogChain))
        XCTAssertFalse(result.effects.contains(.recordOutcome(.completed)))
        XCTAssertLessThan(result.effects.firstIndex(of: .scheduleSnooze(minutes: 9))!,
                          result.effects.firstIndex(of: .stopAudio)!)
    }

    func testSnoozeRoundSurvivesWatchdogKeyAndEnforcesLimitAndShortening() {
        let count = SnoozePolicy.count(in: "alarm-date#snooze2#wd3")
        let settings = SnoozeSettings(duration: 9, limit: 2, escalating: true)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(SnoozePolicy.duration(for: settings, snoozeCount: count), 3)
        XCTAssertFalse(SnoozePolicy.canSnooze(settings: settings, snoozeCount: count, missionSatisfied: true))
        XCTAssertEqual(SnoozePolicy.count(in: "alarm-date#wd1"), 0)
    }

    private func context(
        missionType: MissionType = .math,
        snooze: SnoozeSettings = .default,
        snoozeCount: Int = 0,
        missionSatisfied: Bool = false
    ) -> AlarmStateContext {
        AlarmStateContext(
            snooze: snooze,
            snoozeCount: snoozeCount,
            missionType: missionType,
            missionSatisfied: missionSatisfied
        )
    }

    // MARK: - Invariant 3: Stop is not completion

    func testStopButtonWithAMissionYieldsDismissedUnverifiedNotCompleted() {
        let result = AlarmStateMachine.reduce(
            state: .ringing, event: .stopPressed, context: context(missionType: .steps)
        )

        XCTAssertEqual(result.state, .dismissedUnverified)
        XCTAssertTrue(result.effects.contains(.recordOutcome(.dismissedUnverified)))
        XCTAssertFalse(result.effects.contains(.recordOutcome(.completed)))
    }

    func testStopButtonLeavesTheWatchdogChainArmed() {
        let result = AlarmStateMachine.reduce(
            state: .ringing, event: .stopPressed, context: context(missionType: .steps)
        )

        XCTAssertTrue(result.effects.contains(.preserveWatchdogChain))
        XCTAssertFalse(
            result.effects.contains(.cancelWatchdogChain),
            "Pressing Stop must never cancel Mission Guard — that is the whole mechanism"
        )
    }

    func testStopButtonIsALegitimateDismissalWhenNoMissionIsConfigured() {
        let result = AlarmStateMachine.reduce(
            state: .ringing, event: .stopPressed, context: context(missionType: .none)
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.effects.contains(.cancelWatchdogChain))
    }

    // MARK: - Invariant 1: only a completed mission completes an alarm

    func testOnlyMissionCompletionCancelsTheWatchdogChain() {
        let events: [AlarmEvent] = [
            .arm, .fire, .startMission, .missionFailed(reason: "wrong"),
            .snoozeRequested, .stopPressed, .ringTimeout,
            .appBackgrounded, .appForegrounded, .callStarted, .callEnded
        ]

        for event in events {
            let result = AlarmStateMachine.reduce(
                state: .missionActive, event: event, context: context()
            )
            XCTAssertNotEqual(
                result.state, .completed,
                "\(event) must not complete an alarm"
            )
        }

        let completion = AlarmStateMachine.reduce(
            state: .missionActive, event: .missionCompleted, context: context()
        )
        XCTAssertEqual(completion.state, .completed)
        XCTAssertTrue(completion.effects.contains(.cancelWatchdogChain))
    }

    // MARK: - Invariant 2: failures never dismiss

    func testFailedAttemptKeepsTheAlarmActiveAndRegeneratesTheChallenge() {
        let result = AlarmStateMachine.reduce(
            state: .missionActive,
            event: .missionFailed(reason: "wrong answer"),
            context: context()
        )

        XCTAssertEqual(result.state, .missionActive)
        XCTAssertTrue(result.effects.contains(.regenerateChallenge))
        XCTAssertTrue(result.effects.contains(.recordFailedAttempt(reason: "wrong answer")))
    }

    func testManyConsecutiveFailuresNeverResolveTheAlarm() {
        var state = AlarmState.missionActive
        for index in 0..<250 {
            let result = AlarmStateMachine.reduce(
                state: state,
                event: .missionFailed(reason: "attempt \(index)"),
                context: context()
            )
            state = result.state
        }
        XCTAssertEqual(state, .missionActive, "Repeated failures must not dismiss or dead-end")
    }

    // MARK: - Invariant 4: lifecycle events do not resolve alarms

    func testBackgroundingDuringAMissionPreservesProgress() {
        let backgrounded = AlarmStateMachine.reduce(
            state: .missionActive, event: .appBackgrounded, context: context()
        )
        XCTAssertEqual(backgrounded.state, .missionActive)
        XCTAssertTrue(backgrounded.effects.contains(.preserveMissionProgress))

        let foregrounded = AlarmStateMachine.reduce(
            state: backgrounded.state, event: .appForegrounded, context: context()
        )
        XCTAssertEqual(foregrounded.state, .missionActive)
        XCTAssertFalse(foregrounded.state.isTerminal)
    }

    // MARK: - Invariant 5: calls never cause a missed alarm

    func testCallDuringAlarmSuppressesAudioButKeepsTheAlarmRinging() {
        let result = AlarmStateMachine.reduce(
            state: .ringing, event: .callStarted, context: context()
        )

        XCTAssertEqual(result.state, .ringing, "A call must never turn a ringing alarm into a missed one")
        XCTAssertTrue(result.effects.contains(.markAudioSuppressed(.phoneCall)))
        XCTAssertFalse(result.effects.contains(.recordOutcome(.missed)))
    }

    func testAlarmRePresentsWhenTheCallEnds() {
        let result = AlarmStateMachine.reduce(
            state: .missionActive, event: .callEnded, context: context()
        )

        XCTAssertEqual(result.state, .missionActive)
        XCTAssertTrue(result.effects.contains(.rePresentAlarm))
        XCTAssertTrue(result.effects.contains(.startAudio))
    }

    func testRouteChangeSendsAudioBackToTheSpeaker() {
        let result = AlarmStateMachine.reduce(
            state: .ringing, event: .audioRouteChanged, context: context()
        )
        XCTAssertTrue(result.effects.contains(.rerouteAudioToSpeaker))
        XCTAssertEqual(result.state, .ringing, "Unplugging headphones must not stop the alarm")
    }

    // MARK: - Snooze

    func testSnoozeIsRecordedAsSnoozeAndNeverAsCompletion() {
        let result = AlarmStateMachine.reduce(
            state: .ringing, event: .snoozeRequested, context: context()
        )

        XCTAssertEqual(result.state, .snoozed)
        XCTAssertTrue(result.effects.contains(.recordOutcome(.snoozed)))
        XCTAssertFalse(result.effects.contains(.recordOutcome(.completed)))
        XCTAssertFalse(result.effects.contains(.cancelWatchdogChain))
    }

    func testSnoozeIsRefusedOnceTheLimitIsReached() {
        let settings = SnoozeSettings(isEnabled: true, duration: 9, limit: 2)
        let result = AlarmStateMachine.reduce(
            state: .ringing,
            event: .snoozeRequested,
            context: context(snooze: settings, snoozeCount: 2)
        )

        XCTAssertEqual(result.state, .ringing, "The mission must become the only way out")
        XCTAssertFalse(result.effects.contains(.recordOutcome(.snoozed)))
    }

    func testSnoozeIsRefusedWhenItCostsAMissionThatIsNotDone() {
        let settings = SnoozeSettings(costsMission: true)
        let result = AlarmStateMachine.reduce(
            state: .ringing,
            event: .snoozeRequested,
            context: context(snooze: settings, missionSatisfied: false)
        )

        XCTAssertEqual(result.state, .ringing)

        let allowed = AlarmStateMachine.reduce(
            state: .ringing,
            event: .snoozeRequested,
            context: context(snooze: settings, missionSatisfied: true)
        )
        XCTAssertEqual(allowed.state, .snoozed)
    }

    func testSnoozeIsRefusedWhenDisabled() {
        let settings = SnoozeSettings(isEnabled: false)
        let result = AlarmStateMachine.reduce(
            state: .ringing, event: .snoozeRequested, context: context(snooze: settings)
        )
        XCTAssertEqual(result.state, .ringing)
    }

    func testEscalatingSnoozeGetsShorter() {
        let settings = SnoozeSettings(duration: 9, limit: nil, escalating: true)
        XCTAssertEqual(SnoozePolicy.duration(for: settings, snoozeCount: 0), 9)
        XCTAssertEqual(SnoozePolicy.duration(for: settings, snoozeCount: 1), 5)
        XCTAssertEqual(SnoozePolicy.duration(for: settings, snoozeCount: 2), 3)
        XCTAssertEqual(SnoozePolicy.duration(for: settings, snoozeCount: 9), 3)
    }

    func testNonEscalatingSnoozeIsConstant() {
        let settings = SnoozeSettings(duration: 10, escalating: false)
        XCTAssertEqual(SnoozePolicy.duration(for: settings, snoozeCount: 5), 10)
    }

    // MARK: - Timeout

    func testRingTimeoutMarksMissedButKeepsTheChainArmed() {
        let result = AlarmStateMachine.reduce(
            state: .ringing, event: .ringTimeout, context: context()
        )

        XCTAssertEqual(result.state, .missed)
        XCTAssertTrue(result.effects.contains(.recordOutcome(.missed)))
        XCTAssertTrue(result.effects.contains(.preserveWatchdogChain))
    }

    // MARK: - Outcome semantics

    func testTheThreeOutcomesAreDistinct() {
        XCTAssertTrue(AlarmOutcome.completed.isSuccess)
        XCTAssertFalse(AlarmOutcome.dismissedUnverified.isSuccess)
        XCTAssertFalse(AlarmOutcome.snoozed.isSuccess)
        XCTAssertFalse(AlarmOutcome.missed.isSuccess)
    }
}
