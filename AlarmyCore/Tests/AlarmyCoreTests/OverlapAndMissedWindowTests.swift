import XCTest
@testable import AlarmyCore

final class OverlapResolverTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func pending(_ name: String, offset: TimeInterval, mission: MissionConfig) -> PendingAlarm {
        let alarm = Alarm(name: name, mission: mission)
        return PendingAlarm(
            alarm: alarm,
            occurrence: ScheduledOccurrence(
                alarmID: alarm.id,
                fireDate: base.addingTimeInterval(offset),
                key: "\(name)-key"
            )
        )
    }

    func testAlarmsWithinTheWindowMergeIntoOneSession() {
        let sessions = OverlapResolver().resolve([
            pending("Gym", offset: 0, mission: MissionConfig(type: .math, difficulty: .easy)),
            pending("Class", offset: 60, mission: MissionConfig(type: .steps, difficulty: .medium))
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].isMerged)
        // Rule 2: earliest time wins.
        XCTAssertEqual(sessions[0].fireDate, base)
        // Rule 2: hardest mission wins.
        XCTAssertEqual(sessions[0].mission.type, .steps)
        // Rule 3: no alarm is hidden.
        XCTAssertEqual(sessions[0].displayName, "Gym + Class")
        XCTAssertEqual(sessions[0].alarmIDs.count, 2)
    }

    func testAlarmsBeyondTheWindowStaySeparate() {
        let sessions = OverlapResolver().resolve([
            pending("Gym", offset: 0, mission: .default),
            pending("Class", offset: 120, mission: .default)
        ])

        XCTAssertEqual(sessions.count, 2)
        XCTAssertFalse(sessions[0].isMerged)
        XCTAssertFalse(sessions[1].isMerged)
    }

    func testMergingIsAnchoredNotTransitive() {
        // 0s, 80s, 160s: the first two merge, but the chain must not run away.
        let sessions = OverlapResolver().resolve([
            pending("A", offset: 0, mission: .default),
            pending("B", offset: 80, mission: .default),
            pending("C", offset: 160, mission: .default)
        ])

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].members.count, 2)
        XCTAssertEqual(sessions[1].members.count, 1)
    }

    func testNoAlarmIsEverSilentlyDropped() {
        let input = [
            pending("A", offset: 0, mission: .default),
            pending("B", offset: 30, mission: .default),
            pending("C", offset: 500, mission: .default),
            pending("D", offset: 520, mission: .default)
        ]

        let sessions = OverlapResolver().resolve(input)
        let recovered = sessions.flatMap(\.members).count

        XCTAssertEqual(recovered, input.count, "Merging must never swallow an alarm")
    }

    func testUnorderedInputIsHandled() {
        let sessions = OverlapResolver().resolve([
            pending("Later", offset: 60, mission: .default),
            pending("Earlier", offset: 0, mission: .default)
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].fireDate, base)
        XCTAssertEqual(sessions[0].displayName, "Earlier + Later")
    }

    func testLaterSessionIsBlockedByAnUnresolvedEarlierOne() {
        let sessions = OverlapResolver().resolve([
            pending("First", offset: 0, mission: .default),
            pending("Second", offset: 600, mission: .default)
        ])

        let resolver = OverlapResolver()
        XCTAssertTrue(resolver.isBlocked(sessions[1], byUnresolved: [sessions[0]]))
        XCTAssertFalse(resolver.isBlocked(sessions[0], byUnresolved: []))
    }

    func testEmptyInputProducesNoSessions() {
        XCTAssertTrue(OverlapResolver().resolve([]).isEmpty)
    }
}

final class MissedWindowPolicyTests: XCTestCase {

    private let scheduled = Date(timeIntervalSince1970: 1_780_000_000)

    func testAlarmMissedInsideTheGracePeriodRingsImmediately() {
        let policy = MissedWindowPolicy(rule: .gracePeriod, graceMinutes: 15)
        let decision = policy.decide(scheduledAt: scheduled, now: scheduled.addingTimeInterval(5 * 60))

        guard case .triggerNow = decision else {
            return XCTFail("Expected the alarm to ring, got \(decision)")
        }
    }

    func testAlarmMissedBeyondTheGracePeriodIsSkippedAndRecorded() {
        let policy = MissedWindowPolicy(rule: .gracePeriod, graceMinutes: 15)
        let decision = policy.decide(scheduledAt: scheduled, now: scheduled.addingTimeInterval(45 * 60))

        guard case .skipAndRecordMissed = decision else {
            return XCTFail("Expected the alarm to be recorded as missed, got \(decision)")
        }
    }

    func testFutureAlarmIsNotYetDue() {
        let policy = MissedWindowPolicy()
        XCTAssertEqual(
            policy.decide(scheduledAt: scheduled, now: scheduled.addingTimeInterval(-60)),
            .notYetDue
        )
    }

    func testAlwaysTriggerRingsHoweverLate() {
        let policy = MissedWindowPolicy(rule: .alwaysTrigger)
        guard case .triggerNow = policy.decide(
            scheduledAt: scheduled, now: scheduled.addingTimeInterval(10 * 3600)
        ) else {
            return XCTFail("Expected the alarm to ring")
        }
    }

    func testAlwaysSkipNeverRings() {
        let policy = MissedWindowPolicy(rule: .alwaysSkip)
        guard case .skipAndRecordMissed = policy.decide(
            scheduledAt: scheduled, now: scheduled.addingTimeInterval(60)
        ) else {
            return XCTFail("Expected the alarm to be skipped")
        }
    }

    func testUserIsAlwaysToldWhatHappened() {
        let policy = MissedWindowPolicy()

        let triggered = policy.decide(scheduledAt: scheduled, now: scheduled.addingTimeInterval(120))
        let skipped = policy.decide(scheduledAt: scheduled, now: scheduled.addingTimeInterval(3600))

        XCTAssertNotNil(policy.disclosure(for: triggered, alarmName: "Gym"))
        XCTAssertNotNil(policy.disclosure(for: skipped, alarmName: "Gym"))
        XCTAssertNil(policy.disclosure(for: .notYetDue, alarmName: "Gym"))

        XCTAssertTrue(policy.disclosure(for: skipped, alarmName: "Gym")!.contains("Gym"))
    }
}
