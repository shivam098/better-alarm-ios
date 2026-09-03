import Foundation

/// A single pre-scheduled follow-up alarm.
public struct WatchdogEntry: Hashable, Sendable {
    /// 1-based position in the chain.
    public let index: Int
    public let fireDate: Date
    public let key: String
    /// The mission to present, already escalated where applicable.
    public let mission: MissionConfig
    /// Title shown on the system alert.
    public let alertTitle: String

    public init(index: Int, fireDate: Date, key: String, mission: MissionConfig, alertTitle: String) {
        self.index = index
        self.fireDate = fireDate
        self.key = key
        self.mission = mission
        self.alertTitle = alertTitle
    }
}

public struct WatchdogPlan: Hashable, Sendable {
    public let parentKey: String
    public let entries: [WatchdogEntry]

    public var isEmpty: Bool { entries.isEmpty }
}

/// Builds the Mission Guard watchdog chain (PRD §6.2, REL-1 … REL-3).
///
/// Why this exists: the AlarmKit alert always shows a Stop button that a
/// third-party app cannot remove, so a user can silence the alarm without
/// completing the mission. The chain brings the alarm back until the mission is
/// genuinely completed.
///
/// Why it is *pre-scheduled*: iOS gives no guaranteed background execution after
/// a Stop, so the app cannot re-arm itself reactively. Every follow-up must
/// already be committed to the system at the time the alarm is created.
public struct WatchdogPlanner: Sendable {
    /// Minutes after the parent alarm at which follow-ups fire.
    public static let offsets = [1, 3, 6, 10, 15, 20, 25, 30, 40, 50, 60]

    /// Cap on follow-ups per alarm, to stay inside the system scheduling budget.
    public var maxEntries: Int
    /// Chain position from which the mission escalates one difficulty step (PRD REL-2).
    public var escalateFromIndex: Int
    public var calendar: Calendar

    public init(maxEntries: Int = 6, escalateFromIndex: Int = 3, calendar: Calendar = .current) {
        self.maxEntries = maxEntries
        self.escalateFromIndex = escalateFromIndex
        self.calendar = calendar
    }

    public func plan(for alarm: Alarm, parentFireDate: Date, parentKey: String) -> WatchdogPlan {
        guard alarm.isGuarded else {
            return WatchdogPlan(parentKey: parentKey, entries: [])
        }

        let window = alarm.missionGuard.windowMinutes
        var entries: [WatchdogEntry] = []

        for (position, offset) in WatchdogPlanner.offsets.enumerated() where offset <= window {
            if entries.count >= maxEntries { break }

            let index = position + 1
            let fireDate = parentFireDate.addingTimeInterval(TimeInterval(offset * 60))

            // Escalate only once the user has repeatedly evaded the mission.
            let shouldEscalate = alarm.missionGuard.escalates && index >= escalateFromIndex
            let mission = shouldEscalate ? alarm.mission.escalated() : alarm.mission

            entries.append(
                WatchdogEntry(
                    index: index,
                    fireDate: fireDate,
                    key: OccurrenceKey.watchdog(parent: parentKey, index: index),
                    mission: mission,
                    alertTitle: "Mission not completed — \(alarm.name)"
                )
            )
        }

        return WatchdogPlan(parentKey: parentKey, entries: entries)
    }
}

// MARK: - Scheduling budget

/// Prioritises pending system alarms when the app has more to schedule than the
/// platform will accept (PRD REL-3).
///
/// Priority order: alarms in the next 24 hours, then repeating alarms, then
/// watchdogs belonging to more distant alarms.
public struct SchedulingBudget: Sendable {
    public var capacity: Int
    public var calendar: Calendar

    public init(capacity: Int = 64, calendar: Calendar = .current) {
        self.capacity = capacity
        self.calendar = calendar
    }

    public struct Request: Hashable, Sendable {
        public let key: String
        public let fireDate: Date
        public let isWatchdog: Bool
        public let isRepeating: Bool

        public init(key: String, fireDate: Date, isWatchdog: Bool, isRepeating: Bool) {
            self.key = key
            self.fireDate = fireDate
            self.isWatchdog = isWatchdog
            self.isRepeating = isRepeating
        }
    }

    /// Returns the subset that fits, highest priority first.
    public func prioritise(_ requests: [Request], now: Date) -> [Request] {
        let horizon = now.addingTimeInterval(24 * 60 * 60)

        func rank(_ request: Request) -> Int {
            let imminent = request.fireDate <= horizon
            // Lower is better.
            if imminent && !request.isWatchdog { return 0 }
            if imminent && request.isWatchdog { return 1 }
            if request.isRepeating { return 2 }
            return 3
        }

        return requests
            .filter { $0.fireDate > now }
            .sorted { lhs, rhs in
                let lr = rank(lhs), rr = rank(rhs)
                if lr != rr { return lr < rr }
                return lhs.fireDate < rhs.fireDate
            }
            .prefix(capacity)
            .map { $0 }
    }
}
