import Foundation

/// Headline numbers for the statistics screen.
///
/// Deliberately small: the PRD requires statistics to be understandable rather
/// than an overwhelming dashboard (HIS-6), so this is capped at what fits on one
/// screen.
public struct WakeStatistics: Hashable, Sendable {
    public let totalAlarms: Int
    public let completedCount: Int
    public let snoozedCount: Int
    public let missedCount: Int
    public let dismissedUnverifiedCount: Int
    public let averageSnoozesPerAlarm: Double
    public let averageTimeToComplete: TimeInterval?
    /// Average of the completed wake-up times, as minutes past midnight.
    public let averageWakeMinuteOfDay: Int?
    public let mostUsedMission: MissionType?
    public let currentStreak: Int
    public let longestStreak: Int

    public var completionRate: Double {
        totalAlarms > 0 ? Double(completedCount) / Double(totalAlarms) : 0
    }

    /// The metric that matters most for the product's promise: how often the
    /// alarm was silenced without the user proving they were awake.
    public var silentDismissalRate: Double {
        totalAlarms > 0 ? Double(dismissedUnverifiedCount) / Double(totalAlarms) : 0
    }

    public static let empty = WakeStatistics(
        totalAlarms: 0, completedCount: 0, snoozedCount: 0, missedCount: 0,
        dismissedUnverifiedCount: 0, averageSnoozesPerAlarm: 0,
        averageTimeToComplete: nil, averageWakeMinuteOfDay: nil,
        mostUsedMission: nil, currentStreak: 0, longestStreak: 0
    )
}

public enum StatisticsCalculator {

    public static func summarise(
        _ occurrences: [AlarmOccurrence],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> WakeStatistics {
        let resolved = occurrences.filter { $0.outcome != nil }
        guard !resolved.isEmpty else { return .empty }

        let completed = resolved.filter { $0.outcome == .completed }

        let times = completed.compactMap { $0.timeToCompleteMS }
        let averageTime: TimeInterval? = times.isEmpty
            ? nil
            : TimeInterval(times.reduce(0, +)) / Double(times.count) / 1000.0

        let wakeMinutes = completed.compactMap { occurrence -> Int? in
            guard let resolvedAt = occurrence.resolvedAt else { return nil }
            let c = calendar.dateComponents([.hour, .minute], from: resolvedAt)
            guard let hour = c.hour, let minute = c.minute else { return nil }
            return hour * 60 + minute
        }
        let averageWake = wakeMinutes.isEmpty ? nil : wakeMinutes.reduce(0, +) / wakeMinutes.count

        var missionCounts: [MissionType: Int] = [:]
        for occurrence in resolved {
            missionCounts[occurrence.missionType, default: 0] += 1
        }
        let mostUsed = missionCounts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            // Stable tie-break so the UI does not flicker between equals.
            return lhs.key.rawValue > rhs.key.rawValue
        }?.key

        let totalSnoozes = resolved.reduce(0) { $0 + $1.snoozeCount }
        let streaks = self.streaks(for: completed, calendar: calendar, now: now)

        return WakeStatistics(
            totalAlarms: resolved.count,
            completedCount: completed.count,
            snoozedCount: resolved.filter { $0.outcome == .snoozed }.count,
            missedCount: resolved.filter { $0.outcome == .missed }.count,
            dismissedUnverifiedCount: resolved.filter { $0.outcome == .dismissedUnverified }.count,
            averageSnoozesPerAlarm: Double(totalSnoozes) / Double(resolved.count),
            averageTimeToComplete: averageTime,
            averageWakeMinuteOfDay: averageWake,
            mostUsedMission: mostUsed,
            currentStreak: streaks.current,
            longestStreak: streaks.longest
        )
    }

    /// Wake-up streaks with a forgiving grace rule (PRD HIS-4).
    ///
    /// One missed day may be forgiven per seven days of streak already earned,
    /// so a single bad morning does not erase months of consistency.
    public static func streaks(
        for completed: [AlarmOccurrence],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> (current: Int, longest: Int) {
        let days = Set(
            completed.compactMap { $0.resolvedAt }.map { calendar.startOfDay(for: $0) }
        )
        guard !days.isEmpty else { return (0, 0) }

        // Current streak: walk backwards from today.
        var current = 0
        var gracesUsed = 0
        var cursor = calendar.startOfDay(for: now)

        // Today may simply not have happened yet; that must not break a streak.
        if !days.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        while true {
            if days.contains(cursor) {
                current += 1
            } else {
                let allowedGraces = 1 + current / 7
                if gracesUsed < allowedGraces {
                    gracesUsed += 1
                } else {
                    break
                }
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous

            // Stop once we are past the earliest recorded day.
            if let earliest = days.min(), cursor < earliest { break }
        }

        // Longest streak counts strictly consecutive days, then is clamped up to
        // the current streak. Without the clamp a graced current streak could
        // exceed the recorded longest, which reads as a bug in the UI.
        let sorted = days.sorted()
        var longest = 1
        var run = 1
        for index in 1..<max(1, sorted.count) {
            let previous = sorted[index - 1]
            let day = sorted[index]
            let gap = calendar.dateComponents([.day], from: previous, to: day).day ?? 0
            if gap == 1 {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        return (current, max(longest, current))
    }
}
