import Foundation
import AlarmyCore
import CryptoKit

/// What role a scheduled system alarm plays in the Mission Guard chain.
public enum SystemAlarmRole: Hashable, Sendable {
    /// The alarm the user actually set.
    case primary
    /// A pre-scheduled follow-up that fires if the mission was never completed.
    case watchdog(index: Int)
    /// A one-off alarm created when the user snoozed.
    case snooze(round: Int)
    case wakeCheck
    case wakeReAlarm

    var isWatchdog: Bool {
        if case .watchdog = self { return true }
        return false
    }
}

/// A platform-independent description of one system alarm to be scheduled.
///
/// Nothing here mentions AlarmKit. That is deliberate: it lets the coordinator,
/// the previews and the tests work against a fake scheduler, and confines every
/// AlarmKit symbol to `AlarmKitScheduler`.
public struct SystemAlarmRequest: Identifiable, Hashable, Sendable {
    /// Deterministically derived from `occurrenceKey`, so re-scheduling the same
    /// occurrence replaces rather than duplicates it (PRD TIM-5).
    public let id: UUID
    public let alarmID: UUID
    public let occurrenceKey: String
    public let fireDate: Date
    public let title: String
    public let role: SystemAlarmRole
    public let mission: MissionConfig
    public let soundID: String
    public let allowSnooze: Bool
    public let snoozeMinutes: Int
    public let isRepeating: Bool

    public init(
        alarmID: UUID,
        occurrenceKey: String,
        fireDate: Date,
        title: String,
        role: SystemAlarmRole,
        mission: MissionConfig,
        soundID: String,
        allowSnooze: Bool,
        snoozeMinutes: Int,
        isRepeating: Bool
    ) {
        self.id = SystemAlarmRequest.identifier(for: occurrenceKey)
        self.alarmID = alarmID
        self.occurrenceKey = occurrenceKey
        self.fireDate = fireDate
        self.title = title
        self.role = role
        self.mission = mission
        self.soundID = soundID
        self.allowSnooze = allowSnooze
        self.snoozeMinutes = snoozeMinutes
        self.isRepeating = isRepeating
    }

    /// Full-key digest: nearby suffixes must not collapse to the same timer.
    public static func identifier(for occurrenceKey: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(occurrenceKey.utf8)).prefix(16))
        // UUIDv8 reserves this layout for application-defined identifiers.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Retained only to cancel timers created before the digest migration.
    static func legacyIdentifier(for occurrenceKey: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        // FNV-1a over the key, expanded to 16 bytes by re-hashing with a counter.
        for slot in 0..<16 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            hash = (hash ^ UInt64(slot)) &* 0x1000_0000_01b3
            for byte in occurrenceKey.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
            bytes[slot] = UInt8(truncatingIfNeeded: hash >> 24)
        }
        // Stamp version 5 / RFC 4122 variant so the value is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public enum SystemAlarmAuthorization: String, Sendable {
    case notDetermined
    case authorized
    case denied
    /// The OS build does not provide AlarmKit at all.
    case unavailable

    public var canScheduleReliably: Bool { self == .authorized }
}

public enum SystemAlarmError: Error, LocalizedError {
    case notAuthorized
    case unavailable
    case schedulingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Alarmy doesn't have permission to schedule alarms yet."
        case .unavailable:
            return "This device can't schedule reliable alarms. Alarmy needs iOS 26 or later."
        case .schedulingFailed(let detail):
            return "The alarm couldn't be scheduled: \(detail)"
        }
    }
}

/// What the system tells us about an alarm we scheduled.
public enum SystemAlarmEvent: Hashable, Sendable {
    /// The alarm is on screen and making noise right now.
    case alerting(id: UUID)
    /// The system no longer holds this alarm.
    case ended(id: UUID)
}

/// The seam between our alarm logic and the operating system.
///
/// Implemented for real by `AlarmKitScheduler` and faked in previews/tests.
public protocol SystemAlarmScheduling: Sendable {
    func authorizationStatus() async -> SystemAlarmAuthorization
    @discardableResult
    func requestAuthorization() async -> SystemAlarmAuthorization

    /// Schedules (or replaces) each request. Implementations must be idempotent.
    func schedule(_ requests: [SystemAlarmRequest]) async throws

    func cancel(ids: [UUID]) async
    /// Silences a currently-ringing alarm without touching anything else.
    func stopRinging(id: UUID) async

    /// Identifiers the system currently holds, used for reconciliation.
    func pendingIdentifiers() async -> Set<UUID>

    /// A live stream of state changes, so the app can react when an alarm starts
    /// ringing while it is already open.
    func events() -> AsyncStream<SystemAlarmEvent>
}
