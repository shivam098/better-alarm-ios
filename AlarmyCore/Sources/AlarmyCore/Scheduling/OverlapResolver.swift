import Foundation

/// An alarm together with its next computed firing.
public struct PendingAlarm: Hashable, Sendable {
    public let alarm: Alarm
    public let occurrence: ScheduledOccurrence

    public init(alarm: Alarm, occurrence: ScheduledOccurrence) {
        self.alarm = alarm
        self.occurrence = occurrence
    }
}

/// One or more alarms presented to the user as a single wake-up event.
public struct AlarmSession: Identifiable, Hashable, Sendable {
    public var id: String { key }
    /// The session key is the earliest member's occurrence key.
    public let key: String
    public let fireDate: Date
    /// Every alarm folded into this session, earliest first. Never empty.
    public let members: [PendingAlarm]
    /// Combined name, e.g. "Gym + Class".
    public let displayName: String
    /// The hardest mission among the members.
    public let mission: MissionConfig

    public var alarmIDs: [UUID] { members.map(\.alarm.id) }
    public var isMerged: Bool { members.count > 1 }
}

/// Decides what happens when two alarms land close together (PRD INT-12).
///
/// The rule is deliberately deterministic and surfaced in Settings, because an
/// alarm that silently swallows another alarm is a safety problem.
public struct OverlapResolver: Sendable {
    /// Alarms within this many seconds of each other become one session.
    public var mergeWindow: TimeInterval

    public init(mergeWindow: TimeInterval = 90) {
        self.mergeWindow = mergeWindow
    }

    /// Folds close-together alarms into sessions.
    ///
    /// Merging is anchored on the first alarm of each session rather than being
    /// transitive, so a long chain of alarms 80 seconds apart cannot collapse
    /// into one unbounded session.
    public func resolve(_ pending: [PendingAlarm]) -> [AlarmSession] {
        let sorted = pending.sorted { $0.occurrence.fireDate < $1.occurrence.fireDate }
        var sessions: [AlarmSession] = []
        var bucket: [PendingAlarm] = []

        func flush() {
            guard let anchor = bucket.first else { return }
            // Rule 2: the session adopts the earliest time and the hardest mission.
            let hardest = bucket.max { $0.alarm.mission.hardnessScore < $1.alarm.mission.hardnessScore }
            // Rule 3: every merged alarm's name is shown; none is hidden.
            let name = bucket.map(\.alarm.name).joined(separator: " + ")

            sessions.append(
                AlarmSession(
                    key: anchor.occurrence.key,
                    fireDate: anchor.occurrence.fireDate,
                    members: bucket,
                    displayName: name,
                    mission: hardest?.alarm.mission ?? anchor.alarm.mission
                )
            )
            bucket = []
        }

        for item in sorted {
            if let anchor = bucket.first {
                let gap = item.occurrence.fireDate.timeIntervalSince(anchor.occurrence.fireDate)
                if gap <= mergeWindow {
                    bucket.append(item)
                    continue
                }
                flush()
            }
            bucket = [item]
        }
        flush()

        return sessions
    }

    /// Rule 5: sessions further apart than the merge window are strictly
    /// sequential — a later session must not ring while an earlier one is still
    /// unresolved.
    public func isBlocked(_ session: AlarmSession, byUnresolved unresolved: [AlarmSession]) -> Bool {
        unresolved.contains { $0.fireDate < session.fireDate }
    }
}
