import Foundation
import AlarmKit

/// Metadata AlarmKit carries alongside the system alarm and hands back to our
/// intents and to the Live Activity.
///
/// It is the only state that survives app termination, so it must hold
/// everything needed to resume a mission cold — after a reboot, with the app
/// never having been launched.
///
/// This lives in its own file because both the app and the widget extension
/// compile it: the Live Activity is typed on `AlarmAttributes<AlarmyMetadata>`.
struct AlarmyMetadata: AlarmMetadata {
    let occurrenceKey: String
    let alarmID: String
    let missionType: String
    let difficulty: Int
    let targetCount: Int
    /// `primary`, `watchdog` or `snooze`.
    let role: String
    /// Position in the Mission Guard chain, or the snooze round.
    let watchdogIndex: Int

    init(request: SystemAlarmRequest) {
        self.occurrenceKey = request.occurrenceKey
        self.alarmID = request.alarmID.uuidString
        self.missionType = request.mission.type.rawValue
        self.difficulty = request.mission.difficulty.rawValue
        self.targetCount = request.mission.targetCount

        switch request.role {
        case .primary:
            self.role = "primary"
            self.watchdogIndex = 0
        case .watchdog(let index):
            self.role = "watchdog"
            self.watchdogIndex = index
        case .snooze(let round):
            self.role = "snooze"
            self.watchdogIndex = round
        case .wakeCheck:
            self.role = "wakeCheck"
            self.watchdogIndex = 0
        case .wakeReAlarm:
            self.role = "wakeReAlarm"
            self.watchdogIndex = 0
        }
    }
}
