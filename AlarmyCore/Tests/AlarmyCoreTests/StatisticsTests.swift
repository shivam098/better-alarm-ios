import XCTest
@testable import AlarmyCore

/// Statistics are the product's honesty mechanism: they must never let a user
/// believe they woke up when they only pressed Stop (PRD MEN-1, HIS-3).
final class StatisticsTests: XCTestCase {

    private let alarmID = UUID()
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func reference(_ day: Int, hour: Int = 7, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    private func occurrence(
        outcome: AlarmOutcome?,
        day: Int,
        hour: Int = 7,
        minute: Int = 0,
        mission: MissionType = .math,
        snoozes: Int = 0,
        timeToCompleteMS: Int? = nil
    ) -> AlarmOccurrence {
        let scheduled = reference(day, hour: hour, minute: minute)
        return AlarmOccurrence(
            alarmID: alarmID,
            occurrenceKey: OccurrenceKey.make(alarmID: alarmID, fireDate: scheduled, calendar: calendar),
            scheduledAt: scheduled,
            firedAt: scheduled,
            resolvedAt: outcome == nil ? nil : scheduled,
            outcome: outcome,
            missionType: mission,
            difficulty: .medium,
            snoozeCount: snoozes,
            timeToCompleteMS: timeToCompleteMS
        )
    }

    // MARK: - Honesty

    func testDismissingWithoutAMissionIsNeverCountedAsWakingUp() {
        let history = [
            occurrence(outcome: .completed, day: 1),
            occurrence(outcome: .dismissedUnverified, day: 2),
            occurrence(outcome: .dismissedUnverified, day: 3),
            occurrence(outcome: .snoozed, day: 4),
            occurrence(outcome: .missed, day: 5)
        ]

        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(6))

        XCTAssertEqual(stats.totalAlarms, 5)
        XCTAssertEqual(stats.completedCount, 1)
        XCTAssertEqual(stats.dismissedUnverifiedCount, 2)
        XCTAssertEqual(stats.completionRate, 0.2, accuracy: 0.0001)
        XCTAssertEqual(stats.silentDismissalRate, 0.4, accuracy: 0.0001)
    }

    func testSnoozingIsNotACompletion() {
        let history = [
            occurrence(outcome: .snoozed, day: 1, snoozes: 3),
            occurrence(outcome: .snoozed, day: 2, snoozes: 1)
        ]

        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(3))

        XCTAssertEqual(stats.completedCount, 0)
        XCTAssertEqual(stats.snoozedCount, 2)
        XCTAssertEqual(stats.completionRate, 0)
        XCTAssertEqual(stats.averageSnoozesPerAlarm, 2.0, accuracy: 0.0001)
    }

    func testUnresolvedOccurrencesAreExcludedFromEveryRate() {
        let history = [
            occurrence(outcome: .completed, day: 1),
            occurrence(outcome: nil, day: 2),
            occurrence(outcome: nil, day: 3)
        ]

        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(4))

        XCTAssertEqual(stats.totalAlarms, 1, "A pending alarm must not dilute the completion rate")
        XCTAssertEqual(stats.completionRate, 1.0, accuracy: 0.0001)
    }

    func testEmptyHistoryProducesEmptyStatistics() {
        XCTAssertEqual(StatisticsCalculator.summarise([], calendar: calendar), .empty)
        XCTAssertEqual(
            StatisticsCalculator.summarise([occurrence(outcome: nil, day: 1)], calendar: calendar),
            .empty
        )
    }

    // MARK: - Aggregates

    func testAverageTimeToCompleteIgnoresUncompletedAlarms() {
        let history = [
            occurrence(outcome: .completed, day: 1, timeToCompleteMS: 10_000),
            occurrence(outcome: .completed, day: 2, timeToCompleteMS: 20_000),
            occurrence(outcome: .completed, day: 3, timeToCompleteMS: 30_000),
            // A silent dismissal is fast, and must not flatter the average.
            occurrence(outcome: .dismissedUnverified, day: 4, timeToCompleteMS: 500)
        ]

        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(5))

        XCTAssertEqual(stats.averageTimeToComplete ?? 0, 20.0, accuracy: 0.0001)
    }

    func testAverageWakeTimeUsesTheCompletionMoment() {
        let history = [
            occurrence(outcome: .completed, day: 1, hour: 6, minute: 30),
            occurrence(outcome: .completed, day: 2, hour: 7, minute: 30)
        ]

        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(3))

        XCTAssertEqual(stats.averageWakeMinuteOfDay, 7 * 60, "Expected an average wake time of 07:00")
    }

    func testMostUsedMissionIsReported() {
        let history = [
            occurrence(outcome: .completed, day: 1, mission: .math),
            occurrence(outcome: .completed, day: 2, mission: .math),
            occurrence(outcome: .dismissedUnverified, day: 3, mission: .math),
            occurrence(outcome: .completed, day: 4, mission: .steps)
        ]

        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(5))

        XCTAssertEqual(stats.mostUsedMission, .math)
    }

    func testAverageTimeIsNilWhenNothingWasEverCompleted() {
        let history = [occurrence(outcome: .missed, day: 1), occurrence(outcome: .missed, day: 2)]
        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(3))

        XCTAssertNil(stats.averageTimeToComplete)
        XCTAssertNil(stats.averageWakeMinuteOfDay)
        XCTAssertEqual(stats.missedCount, 2)
    }

    // MARK: - Streaks (PRD HIS-4)

    func testConsecutiveCompletionsBuildAStreak() {
        let history = (1...5).map { occurrence(outcome: .completed, day: $0) }
        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(5, hour: 20))

        XCTAssertEqual(stats.currentStreak, 5)
        XCTAssertEqual(stats.longestStreak, 5)
    }

    func testOneMissedDayIsForgiven() {
        // Days 1, 2, 4, 5, 6 completed — day 3 missed entirely.
        let history = [1, 2, 4, 5, 6].map { occurrence(outcome: .completed, day: $0) }
        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(6, hour: 20))

        XCTAssertEqual(stats.currentStreak, 5, "A single bad morning must not erase the streak")
    }

    func testASecondMissedDayEndsTheStreak() {
        // Days 2, 4, 6 completed — misses on 3 and 5 exhaust the single grace.
        let history = [2, 4, 6].map { occurrence(outcome: .completed, day: $0) }
        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(6, hour: 20))

        XCTAssertEqual(stats.currentStreak, 2)
    }

    func testTodayNotHavingHappenedYetDoesNotBreakTheStreak() {
        // It is 05:00 and today's alarm has not rung. The streak must hold.
        let history = [1, 2, 3].map { occurrence(outcome: .completed, day: $0) }
        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(4, hour: 5))

        XCTAssertEqual(stats.currentStreak, 3)
    }

    func testSilentDismissalsDoNotContributeToAStreak() {
        let history = [
            occurrence(outcome: .completed, day: 1),
            occurrence(outcome: .dismissedUnverified, day: 2),
            occurrence(outcome: .dismissedUnverified, day: 3),
            occurrence(outcome: .dismissedUnverified, day: 4)
        ]

        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(4, hour: 20))

        XCTAssertEqual(stats.currentStreak, 0, "Pressing Stop must never earn a streak day")
    }

    func testLongestStreakIsNeverSmallerThanTheCurrentStreak() {
        let history = [1, 2, 4, 5, 6].map { occurrence(outcome: .completed, day: $0) }
        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(6, hour: 20))

        XCTAssertGreaterThanOrEqual(
            stats.longestStreak,
            stats.currentStreak,
            "A UI showing 'current 5, longest 3' would look broken"
        )
    }

    func testMultipleCompletionsOnOneDayCountAsOneStreakDay() {
        let history = [
            occurrence(outcome: .completed, day: 1, hour: 6),
            occurrence(outcome: .completed, day: 1, hour: 7),
            occurrence(outcome: .completed, day: 2, hour: 6)
        ]

        let stats = StatisticsCalculator.summarise(history, calendar: calendar, now: reference(2, hour: 20))

        XCTAssertEqual(stats.currentStreak, 2)
        XCTAssertEqual(stats.totalAlarms, 3)
    }
}
