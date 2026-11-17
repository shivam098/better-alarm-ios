import Foundation
import AlarmyCore

/// Builds the full set of system alarms for an alarm: the alarm itself plus its
/// pre-scheduled Mission Guard chain (PRD §6.2).
///
/// Everything is computed up front because iOS grants no guaranteed background
/// execution after the user presses Stop — the app cannot re-arm itself later,
/// so every follow-up must already be committed to the system.
public struct AlarmRequestBuilder: Sendable {
    public var calendar: Calendar
    public var planner: WatchdogPlanner
    public var horizonDays: Int

    public init(calendar: Calendar = .current, horizonDays: Int = 7) {
        self.calendar = calendar
        self.planner = WatchdogPlanner(calendar: calendar)
        self.horizonDays = horizonDays
    }

    /// - Parameter occurrences: how many future firings of a repeating alarm to
    ///   materialise. Repeating alarms are re-topped-up on every app launch and
    ///   after every firing, so this only has to cover the gap between launches.
    public func requests(for alarm: Alarm, from now: Date, occurrences: Int = 2) -> [SystemAlarmRequest] {
        guard alarm.isEnabled else { return [] }

        let calculator = AlarmScheduleCalculator(calendar: calendar)
        let fireDates = calculator.nextFireDates(for: alarm, after: now, limit: occurrences)

        return fireDates.flatMap { requests(for: alarm, firingAt: $0) }
    }

    public func requests(for alarm: Alarm, firingAt fireDate: Date) -> [SystemAlarmRequest] {
        let parentKey = OccurrenceKey.make(alarmID: alarm.id, fireDate: fireDate, calendar: calendar)

        var requests = [
            SystemAlarmRequest(
                alarmID: alarm.id,
                occurrenceKey: parentKey,
                fireDate: fireDate,
                title: alarm.name,
                role: .primary,
                mission: alarm.mission,
                soundID: alarm.soundID,
                allowSnooze: alarm.snooze.isEnabled && !alarm.snooze.costsMission,
                snoozeMinutes: alarm.snooze.duration,
                isRepeating: alarm.isRepeating
            )
        ]

        let plan = planner.plan(for: alarm, parentFireDate: fireDate, parentKey: parentKey)
        requests.append(contentsOf: plan.entries.map { entry in
            SystemAlarmRequest(
                alarmID: alarm.id,
                occurrenceKey: entry.key,
                fireDate: entry.fireDate,
                title: entry.alertTitle,
                role: .watchdog(index: entry.index),
                mission: entry.mission,
                soundID: alarm.audioOptions?.backupSoundID ?? alarm.soundID,
                // A watchdog exists because the user evaded the mission. Letting
                // them snooze it would reopen the loophole (PRD REL-2).
                allowSnooze: false,
                snoozeMinutes: alarm.snooze.duration,
                isRepeating: alarm.isRepeating
            )
        })

        return requests
    }

    /// A single snooze alarm, plus a fresh guard chain anchored to the new time
    /// so a snoozed alarm is still protected (PRD SNZ-5).
    public func snoozeRequests(
        for alarm: Alarm,
        parentKey: String,
        round: Int,
        firingAt fireDate: Date
    ) -> [SystemAlarmRequest] {
        let key = "\(parentKey)#snooze\(round)"

        var requests = [
            SystemAlarmRequest(
                alarmID: alarm.id,
                occurrenceKey: key,
                fireDate: fireDate,
                title: alarm.name,
                role: .snooze(round: round),
                mission: alarm.mission,
                soundID: alarm.soundID,
                allowSnooze: alarm.snooze.isEnabled && SnoozePolicy.remaining(settings: alarm.snooze, snoozeCount: round) != 0,
                snoozeMinutes: SnoozePolicy.duration(for: alarm.snooze, snoozeCount: round),
                isRepeating: false
            )
        ]

        let plan = planner.plan(for: alarm, parentFireDate: fireDate, parentKey: key)
        requests.append(contentsOf: plan.entries.map { entry in
            SystemAlarmRequest(
                alarmID: alarm.id,
                occurrenceKey: entry.key,
                fireDate: entry.fireDate,
                title: entry.alertTitle,
                role: .watchdog(index: entry.index),
                mission: entry.mission,
                soundID: alarm.audioOptions?.backupSoundID ?? alarm.soundID,
                allowSnooze: false,
                snoozeMinutes: alarm.snooze.duration,
                isRepeating: false
            )
        })

        return requests
    }

    public func requests(for check: PendingWakeCheck) -> [SystemAlarmRequest] {
        [
            SystemAlarmRequest(
                alarmID: check.alarm.id, occurrenceKey: check.checkKey,
                fireDate: check.checkAt, title: "Still awake? \(check.alarm.name)",
                role: .wakeCheck, mission: MissionConfig(type: .none),
                soundID: check.alarm.soundID, allowSnooze: false,
                snoozeMinutes: 0, isRepeating: false
            ),
            SystemAlarmRequest(
                alarmID: check.alarm.id, occurrenceKey: check.reAlarmKey,
                fireDate: check.deadline, title: "Wake check missed: \(check.alarm.name)",
                role: .wakeReAlarm, mission: check.alarm.mission,
                soundID: check.alarm.audioOptions?.backupSoundID ?? check.alarm.soundID,
                allowSnooze: false, snoozeMinutes: 0, isRepeating: false
            )
        ]
    }

    /// Trims the full wish-list down to what the platform will accept,
    /// prioritising imminent, non-watchdog alarms (PRD REL-3).
    public func withinBudget(
        _ requests: [SystemAlarmRequest],
        now: Date,
        capacity: Int
    ) -> [SystemAlarmRequest] {
        let budget = SchedulingBudget(capacity: capacity, calendar: calendar)
        let ordered = budget.prioritise(
            requests.map {
                SchedulingBudget.Request(
                    key: $0.occurrenceKey,
                    fireDate: $0.fireDate,
                    isWatchdog: $0.role.isWatchdog,
                    isRepeating: $0.isRepeating
                )
            },
            now: now
        )

        let byKey = Dictionary(requests.map { ($0.occurrenceKey, $0) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { byKey[$0.key] }
    }
}
