import XCTest
@testable import AlarmyCore

/// Scheduling correctness, with particular attention to the cases that make
/// real alarm apps fail: daylight saving, time-zone moves, and duplicates.
final class AlarmScheduleCalculatorTests: XCTestCase {

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: - Basics

    func testNextFireDateForOneTimeAlarmIsTheNextMatchingWallClockTime() {
        let calendar = calendar("Europe/London")
        let subject = AlarmScheduleCalculator(calendar: calendar)
        let alarm = Alarm(name: "Wake up", hour: 7, minute: 30)

        let now = date(calendar, 2026, 6, 10, 22, 0)
        let next = subject.nextFireDate(for: alarm, after: now)

        XCTAssertNotNil(next)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 7)
        XCTAssertEqual(components.minute, 30)
    }

    func testDisabledAlarmNeverFires() {
        let calendar = calendar("Europe/London")
        let subject = AlarmScheduleCalculator(calendar: calendar)
        let alarm = Alarm(hour: 7, minute: 0, isEnabled: false)

        XCTAssertNil(subject.nextFireDate(for: alarm, after: date(calendar, 2026, 6, 10)))
    }

    func testRepeatingAlarmPicksTheEarliestSelectedWeekday() {
        let calendar = calendar("Europe/London")
        let subject = AlarmScheduleCalculator(calendar: calendar)
        let alarm = Alarm(name: "Gym", hour: 6, minute: 0, repeatDays: [.monday, .thursday])

        // 2026-06-09 is a Tuesday, so the next hit is Thursday the 11th.
        let now = date(calendar, 2026, 6, 9, 12, 0)
        let next = subject.nextFireDate(for: alarm, after: now)!

        let components = calendar.dateComponents([.weekday, .day, .hour], from: next)
        XCTAssertEqual(components.weekday, Weekday.thursday.rawValue)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 6)
    }

    // MARK: - Daylight saving (PRD TIM-4)

    func testSpringForwardAlarmAtNonExistentTimeFiresAtNextValidInstant() {
        // On 2026-03-08 US clocks jump 02:00 -> 03:00, so 02:30 does not exist.
        let calendar = calendar("America/New_York")
        let subject = AlarmScheduleCalculator(calendar: calendar)
        let alarm = Alarm(name: "Early", hour: 2, minute: 30)

        let now = date(calendar, 2026, 3, 7, 12, 0)
        let next = subject.nextFireDate(for: alarm, after: now)!

        let components = calendar.dateComponents([.month, .day, .hour], from: next)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 8)
        // The alarm must still ring, at the next instant that exists.
        XCTAssertEqual(components.hour, 3, "A spring-forward alarm must not be silently skipped")
    }

    func testFallBackAlarmAtRepeatedTimeFiresExactlyOnce() {
        // On 2026-11-01 US clocks fall 02:00 -> 01:00, so 01:30 happens twice.
        let calendar = calendar("America/New_York")
        let subject = AlarmScheduleCalculator(calendar: calendar)
        let alarm = Alarm(name: "Daily", hour: 1, minute: 30, repeatDays: Set(Weekday.allCases))

        let now = date(calendar, 2026, 10, 31, 12, 0)
        let occurrences = subject.occurrences(for: alarm, after: now, limit: 3)

        XCTAssertEqual(occurrences.count, 3)

        // No two firings may share an idempotency key (PRD TIM-5).
        let keys = Set(occurrences.map(\.key))
        XCTAssertEqual(keys.count, 3, "DST must not produce duplicate occurrences")

        // Every firing is a distinct, strictly increasing instant.
        let dates = occurrences.map(\.fireDate)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, 3)

        // The 25-hour day must still produce exactly one 01:30 alarm.
        let novemberFirst = dates.filter {
            let c = calendar.dateComponents([.month, .day], from: $0)
            return c.month == 11 && c.day == 1
        }
        XCTAssertEqual(novemberFirst.count, 1, "A fall-back day must ring once, not twice")
    }

    // MARK: - Time zones (PRD TIM-1)

    func testWallClockAlarmFollowsTheUserAcrossTimeZones() {
        let london = calendar("Europe/London")
        let kolkata = calendar("Asia/Kolkata")
        let alarm = Alarm(name: "Wake up", hour: 7, minute: 0, repeatDays: [.wednesday])

        let londonNext = AlarmScheduleCalculator(calendar: london)
            .nextFireDate(for: alarm, after: date(london, 2026, 6, 8, 12, 0))!
        let kolkataNext = AlarmScheduleCalculator(calendar: kolkata)
            .nextFireDate(for: alarm, after: date(kolkata, 2026, 6, 8, 12, 0))!

        // Different absolute instants, but 07:00 local in both places.
        XCTAssertNotEqual(londonNext, kolkataNext)
        XCTAssertEqual(london.dateComponents([.hour], from: londonNext).hour, 7)
        XCTAssertEqual(kolkata.dateComponents([.hour], from: kolkataNext).hour, 7)
    }

    func testAbsoluteAlarmDoesNotMoveWithWallClock() {
        let calendar = calendar("Europe/London")
        let subject = AlarmScheduleCalculator(calendar: calendar)
        let instant = date(calendar, 2026, 6, 11, 7, 0)
        let alarm = Alarm(hour: 7, minute: 0, scheduleMode: .absolute, absoluteDate: instant)

        XCTAssertEqual(subject.nextFireDate(for: alarm, after: date(calendar, 2026, 6, 10)), instant)
        // Already past: it must not fire again.
        XCTAssertNil(subject.nextFireDate(for: alarm, after: date(calendar, 2026, 6, 12)))
    }

    // MARK: - Idempotency (PRD TIM-5)

    func testDeduplicateCollapsesRepeatedReconciliation() {
        let calendar = calendar("Europe/London")
        let subject = AlarmScheduleCalculator(calendar: calendar)
        let alarm = Alarm(hour: 7, minute: 0, repeatDays: [.monday, .tuesday])
        let now = date(calendar, 2026, 6, 7, 12, 0)

        // Simulate reconciliation running twice, as it would after a reboot
        // followed by a time-zone change.
        let first = subject.occurrences(for: alarm, after: now, limit: 4)
        let second = subject.occurrences(for: alarm, after: now, limit: 4)
        let merged = AlarmScheduleCalculator.deduplicate(first + second)

        XCTAssertEqual(merged.count, first.count)
    }

    func testOccurrenceKeyIsStableForTheSameFiring() {
        let calendar = calendar("Europe/London")
        let id = UUID()
        let fire = date(calendar, 2026, 6, 11, 7, 0)

        XCTAssertEqual(
            OccurrenceKey.make(alarmID: id, fireDate: fire, calendar: calendar),
            OccurrenceKey.make(alarmID: id, fireDate: fire, calendar: calendar)
        )
    }

    func testNextFireDatesAreStrictlyIncreasing() {
        let calendar = calendar("Europe/London")
        let subject = AlarmScheduleCalculator(calendar: calendar)
        let alarm = Alarm(hour: 7, minute: 0, repeatDays: Set(Weekday.allCases))

        let dates = subject.nextFireDates(
            for: alarm,
            after: date(calendar, 2026, 6, 1, 12, 0),
            limit: 10
        )

        XCTAssertEqual(dates.count, 10)
        for index in 1..<dates.count {
            XCTAssertGreaterThan(dates[index], dates[index - 1])
        }
    }
}
