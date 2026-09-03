import XCTest
@testable import AlarmyCore

/// Mission Guard is the mechanism that makes a mission alarm possible on iOS,
/// given that the system Stop button cannot be removed.
final class MissionGuardTests: XCTestCase {

    private let parentFireDate = Date(timeIntervalSince1970: 1_780_000_000)

    private func alarm(
        guardSettings: MissionGuardSettings = .default,
        mission: MissionConfig = MissionConfig(type: .math, difficulty: .medium)
    ) -> Alarm {
        Alarm(name: "Gym", hour: 6, minute: 30, mission: mission, missionGuard: guardSettings)
    }

    func testDefaultChainIsSixFollowUpsAcrossThirtyMinutes() {
        let planner = WatchdogPlanner()
        let plan = planner.plan(for: alarm(), parentFireDate: parentFireDate, parentKey: "P")

        XCTAssertEqual(plan.entries.count, 6)
        XCTAssertEqual(plan.entries.first?.fireDate, parentFireDate.addingTimeInterval(60))
        XCTAssertTrue(plan.entries.allSatisfy {
            $0.fireDate <= parentFireDate.addingTimeInterval(30 * 60)
        })
    }

    func testChainIsStrictlyIncreasingAndUniquelyKeyed() {
        let plan = WatchdogPlanner().plan(for: alarm(), parentFireDate: parentFireDate, parentKey: "P")

        let dates = plan.entries.map(\.fireDate)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(plan.entries.map(\.key)).count, plan.entries.count)
        XCTAssertTrue(plan.entries.allSatisfy { $0.key.hasPrefix("P#wd") })
    }

    func testDifficultyEscalatesOnlyAfterRepeatedEvasion() {
        let plan = WatchdogPlanner().plan(for: alarm(), parentFireDate: parentFireDate, parentKey: "P")

        // The first two follow-ups stay at the configured difficulty...
        XCTAssertEqual(plan.entries[0].mission.difficulty, .medium)
        XCTAssertEqual(plan.entries[1].mission.difficulty, .medium)
        // ...then the alarm gets harder to ignore.
        XCTAssertEqual(plan.entries[2].mission.difficulty, .hard)
        XCTAssertEqual(plan.entries[5].mission.difficulty, .hard)
    }

    func testEscalationCanBeTurnedOff() {
        let settings = MissionGuardSettings(isEnabled: true, windowMinutes: 30, escalates: false)
        let plan = WatchdogPlanner().plan(
            for: alarm(guardSettings: settings), parentFireDate: parentFireDate, parentKey: "P"
        )

        XCTAssertTrue(plan.entries.allSatisfy { $0.mission.difficulty == .medium })
    }

    func testShorterWindowProducesFewerFollowUps() {
        let settings = MissionGuardSettings(isEnabled: true, windowMinutes: 15)
        let plan = WatchdogPlanner().plan(
            for: alarm(guardSettings: settings), parentFireDate: parentFireDate, parentKey: "P"
        )

        // Offsets 1, 3, 6, 10, 15 fall inside a 15-minute window.
        XCTAssertEqual(plan.entries.count, 5)
    }

    func testGuardIsSkippedWhenDisabledOrWindowIsZero() {
        let disabled = MissionGuardSettings(isEnabled: false)
        XCTAssertTrue(
            WatchdogPlanner().plan(
                for: alarm(guardSettings: disabled), parentFireDate: parentFireDate, parentKey: "P"
            ).isEmpty
        )

        let zeroWindow = MissionGuardSettings(isEnabled: true, windowMinutes: 0)
        XCTAssertTrue(
            WatchdogPlanner().plan(
                for: alarm(guardSettings: zeroWindow), parentFireDate: parentFireDate, parentKey: "P"
            ).isEmpty
        )
    }

    func testAlarmWithoutAMissionNeedsNoGuard() {
        let noMission = MissionConfig(type: .none)
        let subject = alarm(mission: noMission)

        XCTAssertFalse(subject.isGuarded)
        XCTAssertTrue(
            WatchdogPlanner().plan(for: subject, parentFireDate: parentFireDate, parentKey: "P").isEmpty
        )
    }

    // MARK: - Scheduling budget (PRD REL-3)

    func testBudgetPrioritisesImminentRealAlarmsOverDistantWatchdogs() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let budget = SchedulingBudget(capacity: 3)

        let requests = [
            SchedulingBudget.Request(
                key: "distant-watchdog", fireDate: now.addingTimeInterval(72 * 3600),
                isWatchdog: true, isRepeating: false
            ),
            SchedulingBudget.Request(
                key: "imminent-alarm", fireDate: now.addingTimeInterval(3600),
                isWatchdog: false, isRepeating: false
            ),
            SchedulingBudget.Request(
                key: "imminent-watchdog", fireDate: now.addingTimeInterval(3660),
                isWatchdog: true, isRepeating: false
            ),
            SchedulingBudget.Request(
                key: "distant-repeating", fireDate: now.addingTimeInterval(96 * 3600),
                isWatchdog: false, isRepeating: true
            )
        ]

        let selected = budget.prioritise(requests, now: now).map(\.key)

        XCTAssertEqual(selected, ["imminent-alarm", "imminent-watchdog", "distant-repeating"])
        XCTAssertFalse(selected.contains("distant-watchdog"))
    }

    func testBudgetDropsRequestsInThePast() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let requests = [
            SchedulingBudget.Request(
                key: "past", fireDate: now.addingTimeInterval(-60), isWatchdog: false, isRepeating: false
            )
        ]
        XCTAssertTrue(SchedulingBudget().prioritise(requests, now: now).isEmpty)
    }
}
