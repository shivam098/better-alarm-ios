import Foundation
import os

/// Logging subsystems. Alarm reliability problems are almost always diagnosed
/// after the fact, from a device the developer does not have, so the scheduling
/// and firing paths are logged deliberately and consistently.
///
/// Nothing logged here contains mission content, photos, or anything that could
/// identify the user (PRD PRI-3).
enum AlarmyLog {
    private static let subsystem = "com.alarmy.app"

    static let scheduling = Logger(subsystem: subsystem, category: "scheduling")
    static let firing = Logger(subsystem: subsystem, category: "firing")
    static let mission = Logger(subsystem: subsystem, category: "mission")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let sensors = Logger(subsystem: subsystem, category: "sensors")
}

/// A no-op scheduler used by SwiftUI previews and by the simulator, where
/// AlarmKit cannot deliver real alarms.
actor PreviewAlarmScheduler: SystemAlarmScheduling {
    private var scheduled: [UUID: SystemAlarmRequest] = [:]

    func authorizationStatus() async -> SystemAlarmAuthorization { .authorized }

    @discardableResult
    func requestAuthorization() async -> SystemAlarmAuthorization { .authorized }

    func schedule(_ requests: [SystemAlarmRequest]) async throws {
        for request in requests { scheduled[request.id] = request }
    }

    func cancel(ids: [UUID]) async {
        for id in ids { scheduled.removeValue(forKey: id) }
    }

    func stopRinging(id: UUID) async {}

    func pendingIdentifiers() async -> Set<UUID> { Set(scheduled.keys) }

    nonisolated func events() -> AsyncStream<SystemAlarmEvent> {
        AsyncStream { $0.finish() }
    }

    func snapshot() -> [SystemAlarmRequest] {
        scheduled.values.sorted { $0.fireDate < $1.fireDate }
    }
}
