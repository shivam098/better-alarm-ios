import Foundation

/// The three outcomes the product must keep distinct (PRD MEN-1).
///
/// Conflating `dismissedUnverified` with `completed` is the single most common
/// failure of alarm apps: it lets a half-asleep user believe they got up.
public enum AlarmOutcome: String, Codable, Hashable, Sendable {
    /// The mission was genuinely completed. The only success state.
    case completed
    /// The user pressed the system Stop button without completing the mission.
    case dismissedUnverified
    /// The user snoozed. Explicitly *not* a completion (PRD SNZ-4).
    case snoozed
    /// The alarm was never successfully handled.
    case missed

    public var isSuccess: Bool { self == .completed }

    public var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .dismissedUnverified: return "Dismissed without mission"
        case .snoozed: return "Snoozed"
        case .missed: return "Missed"
        }
    }
}

/// Why the alarm tone may not have been audible. Recorded so the app can tell
/// the user what happened instead of looking broken (PRD INT-6).
public enum AudioSuppressionReason: String, Codable, Hashable, Sendable {
    case none
    case phoneCall
    case audioRoute
    case silentMode

    public var userExplanation: String? {
        switch self {
        case .none: return nil
        case .phoneCall: return "Your alarm was silenced by a phone call."
        case .audioRoute: return "Your alarm played through a connected audio device."
        case .silentMode: return "Your alarm was silenced because alarm permission is turned off."
        }
    }
}

/// Which delivery mechanism served this alarm (PRD §6.3).
public enum DeliveryTier: Int, Codable, Hashable, Sendable {
    /// AlarmKit system alarm. Breaks through Silent Mode and Focus.
    case alarmKit = 1
    /// Notification chain. Respects the mute switch — the user must be warned.
    case notificationChain = 2
    /// Legacy foreground audio. Not marketed as reliable.
    case legacy = 3

    public var isReliable: Bool { self == .alarmKit }
}

/// A single firing of an alarm. One row per ring, written durably *before* the
/// UI updates so a crash cannot lose the record (PRD REL-11).
public struct AlarmOccurrence: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var alarmID: UUID
    /// Idempotency key — see `OccurrenceKey`. Prevents duplicates across reboots,
    /// clock changes, DST shifts and sync merges (PRD TIM-5).
    public var occurrenceKey: String

    public var scheduledAt: Date
    public var firedAt: Date?
    public var resolvedAt: Date?

    public var outcome: AlarmOutcome?
    public var missionType: MissionType
    public var difficulty: MissionDifficulty
    public var attempts: Int
    public var failureReasons: [String]
    public var snoozeCount: Int
    public var timeToCompleteMS: Int?
    public var audioSuppression: AudioSuppressionReason
    public var deliveryTier: DeliveryTier
    /// Set when the configured mission was swapped out at ring time (PRD PRM-5).
    public var substitutedFrom: MissionType?

    public init(
        id: UUID = UUID(),
        alarmID: UUID,
        occurrenceKey: String,
        scheduledAt: Date,
        firedAt: Date? = nil,
        resolvedAt: Date? = nil,
        outcome: AlarmOutcome? = nil,
        missionType: MissionType,
        difficulty: MissionDifficulty,
        attempts: Int = 0,
        failureReasons: [String] = [],
        snoozeCount: Int = 0,
        timeToCompleteMS: Int? = nil,
        audioSuppression: AudioSuppressionReason = .none,
        deliveryTier: DeliveryTier = .alarmKit,
        substitutedFrom: MissionType? = nil
    ) {
        self.id = id
        self.alarmID = alarmID
        self.occurrenceKey = occurrenceKey
        self.scheduledAt = scheduledAt
        self.firedAt = firedAt
        self.resolvedAt = resolvedAt
        self.outcome = outcome
        self.missionType = missionType
        self.difficulty = difficulty
        self.attempts = attempts
        self.failureReasons = failureReasons
        self.snoozeCount = snoozeCount
        self.timeToCompleteMS = timeToCompleteMS
        self.audioSuppression = audioSuppression
        self.deliveryTier = deliveryTier
        self.substitutedFrom = substitutedFrom
    }

    public var isResolved: Bool { outcome != nil }
}

/// Stable idempotency key for one firing of one alarm.
///
/// Any reconciliation pass, time-zone change, DST shift or sync merge that
/// produces the same key is a no-op. This is the mechanism behind PRD TIM-5
/// ("no clock change may create a duplicate alarm").
public enum OccurrenceKey {
    public static func make(alarmID: UUID, fireDate: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        return String(
            format: "%@-%04d%02d%02d-%02d%02d",
            alarmID.uuidString,
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0
        )
    }

    /// Watchdogs share the parent's occurrence key so the whole chain can be
    /// cancelled atomically when the mission is completed.
    public static func watchdog(parent: String, index: Int) -> String {
        "\(parent)#wd\(index)"
    }
}
