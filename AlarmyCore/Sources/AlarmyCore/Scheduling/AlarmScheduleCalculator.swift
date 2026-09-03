import Foundation

/// One computed firing of an alarm.
public struct ScheduledOccurrence: Hashable, Sendable {
    public let alarmID: UUID
    public let fireDate: Date
    public let key: String

    public init(alarmID: UUID, fireDate: Date, key: String) {
        self.alarmID = alarmID
        self.fireDate = fireDate
        self.key = key
    }
}

/// Computes when an alarm should next fire.
///
/// All daylight-saving and time-zone behaviour is delegated to `Calendar`, using
/// the two policies that encode PRD TIM-4 exactly:
///
/// * `matchingPolicy: .nextTime` — if the local time does not exist because the
///   clock sprang forward, fire at the next valid instant.
/// * `repeatedTimePolicy: .first` — if the local time occurs twice because the
///   clock fell back, fire once, on the first occurrence.
public struct AlarmScheduleCalculator: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The next instant this alarm should ring, or `nil` if it never will.
    public func nextFireDate(for alarm: Alarm, after date: Date) -> Date? {
        guard alarm.isEnabled else { return nil }

        switch alarm.scheduleMode {
        case .absolute:
            // A fixed instant in time; it does not move with the time zone.
            guard let absolute = alarm.absoluteDate, absolute > date else { return nil }
            return absolute

        case .wallClock:
            if alarm.isRepeating {
                // Earliest match across every selected weekday.
                return alarm.repeatDays
                    .compactMap { weekday in
                        calendar.nextDate(
                            after: date,
                            matching: DateComponents(
                                hour: alarm.hour,
                                minute: alarm.minute,
                                weekday: weekday.calendarValue
                            ),
                            matchingPolicy: .nextTime,
                            repeatedTimePolicy: .first,
                            direction: .forward
                        )
                    }
                    .min()
            } else {
                return calendar.nextDate(
                    after: date,
                    matching: DateComponents(hour: alarm.hour, minute: alarm.minute),
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                )
            }
        }
    }

    /// The next `limit` firings, used to pre-schedule repeating alarms.
    public func nextFireDates(for alarm: Alarm, after date: Date, limit: Int) -> [Date] {
        guard limit > 0, alarm.isEnabled else { return [] }

        var results: [Date] = []
        var cursor = date

        while results.count < limit {
            guard let next = nextFireDate(for: alarm, after: cursor) else { break }
            // Defensive: `nextDate` must always move forward. If it ever does not,
            // stop rather than loop forever.
            guard next > cursor else { break }
            results.append(next)
            cursor = next
            if !alarm.isRepeating && alarm.scheduleMode == .wallClock { break }
            if alarm.scheduleMode == .absolute { break }
        }
        return results
    }

    /// Next firings as idempotent occurrences.
    public func occurrences(for alarm: Alarm, after date: Date, limit: Int) -> [ScheduledOccurrence] {
        nextFireDates(for: alarm, after: date, limit: limit).map { fireDate in
            ScheduledOccurrence(
                alarmID: alarm.id,
                fireDate: fireDate,
                key: OccurrenceKey.make(alarmID: alarm.id, fireDate: fireDate, calendar: calendar)
            )
        }
    }

    /// Deduplicates occurrences by key.
    ///
    /// Reconciliation after a reboot, a time-zone change or a sync merge routes
    /// through here, which is why those events cannot create duplicate alarms
    /// (PRD TIM-5).
    public static func deduplicate(_ occurrences: [ScheduledOccurrence]) -> [ScheduledOccurrence] {
        var seen = Set<String>()
        var result: [ScheduledOccurrence] = []
        for occurrence in occurrences where seen.insert(occurrence.key).inserted {
            result.append(occurrence)
        }
        return result
    }
}
