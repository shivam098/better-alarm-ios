import Foundation

/// How an alarm's time is interpreted when the device changes time zone (PRD TIM-1 / TIM-2).
public enum ScheduleMode: String, Codable, Hashable, Sendable {
    /// "7:00 AM wherever I am" — the default, and the only sensible mode for a repeating alarm.
    case wallClock
    /// "This exact instant" — for a traveller who means a specific moment in time.
    case absolute
}

/// Snooze configuration (PRD SNZ-1 … SNZ-8).
public struct SnoozeSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Minutes.
    public var duration: Int
    /// `nil` means unlimited.
    public var limit: Int?
    /// Require the mission to be completed *before* granting the snooze (PRD SNZ-6).
    public var costsMission: Bool
    /// Shorten each successive snooze: 9 → 5 → 3 (PRD SNZ-8).
    public var escalating: Bool

    public init(
        isEnabled: Bool = true,
        duration: Int = 9,
        limit: Int? = 3,
        costsMission: Bool = false,
        escalating: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.duration = duration
        self.limit = limit
        self.costsMission = costsMission
        self.escalating = escalating
    }

    public static let `default` = SnoozeSettings()
    public static let allowedDurations = [1, 3, 5, 10, 15, 20, 30, 9]
}

/// Mission Guard — the mechanism that makes a mission alarm possible on iOS.
///
/// The AlarmKit alert always renders a Stop button that the app cannot remove.
/// A user can therefore silence the alarm without completing the mission. Mission
/// Guard answers that by *pre-scheduling* a chain of follow-up system alarms at
/// the time the alarm is created. Completing the mission cancels the chain;
/// pressing Stop does not (PRD §6.2, REL-1 … REL-3).
///
/// The chain must be pre-scheduled because iOS grants no guaranteed background
/// execution with which to re-arm reactively.
public struct MissionGuardSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// How long the app will keep bringing the alarm back, in minutes.
    public var windowMinutes: Int
    /// Raise mission difficulty after repeated evasion (PRD REL-2).
    public var escalates: Bool

    public init(isEnabled: Bool = true, windowMinutes: Int = 30, escalates: Bool = true) {
        self.isEnabled = isEnabled
        self.windowMinutes = windowMinutes
        self.escalates = escalates
    }

    public static let `default` = MissionGuardSettings()
    public static let allowedWindows = [0, 15, 30, 60]
}

/// A user-configured alarm. This is the persisted, synced entity.
public struct Alarm: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// 0...23 in the user's local wall clock.
    public var hour: Int
    /// 0...59.
    public var minute: Int
    /// Empty means a one-time alarm.
    public var repeatDays: Set<Weekday>
    public var isEnabled: Bool
    public var scheduleMode: ScheduleMode
    /// Only meaningful when `scheduleMode == .absolute`.
    public var absoluteDate: Date?

    public var soundID: String
    public var volume: Double
    public var gentleRamp: Bool
    public var vibrationEnabled: Bool
    /// Optional so alarms saved before these features continue to decode.
    public var audioOptions: AlarmAudioOptions?
    public var wakeCheck: WakeCheckSettings?

    public var snooze: SnoozeSettings
    public var mission: MissionConfig
    /// Explicit substitute if the mission's sensors/permissions are unavailable at ring time.
    public var fallbackMission: MissionType?
    public var missionGuard: MissionGuardSettings

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "Alarm",
        hour: Int = 7,
        minute: Int = 0,
        repeatDays: Set<Weekday> = [],
        isEnabled: Bool = true,
        scheduleMode: ScheduleMode = .wallClock,
        absoluteDate: Date? = nil,
        soundID: String = SoundLibrary.defaultSoundID,
        volume: Double = 1.0,
        gentleRamp: Bool = true,
        vibrationEnabled: Bool = true,
        audioOptions: AlarmAudioOptions? = nil,
        wakeCheck: WakeCheckSettings? = nil,
        snooze: SnoozeSettings = .default,
        mission: MissionConfig = .default,
        fallbackMission: MissionType? = nil,
        missionGuard: MissionGuardSettings = .default,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hour = hour
        self.minute = minute
        self.repeatDays = repeatDays
        self.isEnabled = isEnabled
        self.scheduleMode = scheduleMode
        self.absoluteDate = absoluteDate
        self.soundID = soundID
        self.volume = volume
        self.gentleRamp = gentleRamp
        self.vibrationEnabled = vibrationEnabled
        self.audioOptions = audioOptions
        self.wakeCheck = wakeCheck
        self.snooze = snooze
        self.mission = mission
        self.fallbackMission = fallbackMission
        self.missionGuard = missionGuard
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isRepeating: Bool { !repeatDays.isEmpty }

    /// The effective substitute mission, honouring an explicit choice and
    /// otherwise walking the mission's own fallback chain (PRD PRM-4).
    public func resolvedFallback(excluding unavailable: Set<MissionPermission>) -> MissionType {
        if let explicit = fallbackMission,
           explicit != .none, explicit != .combination,
           explicit.requiredPermissions.isEmpty,
           explicit.requiredPermissions.isDisjoint(with: unavailable) {
            return explicit
        }
        for candidate in mission.type.fallbackChain
        where candidate.requiredPermissions.isEmpty && candidate.requiredPermissions.isDisjoint(with: unavailable) {
            return candidate
        }
        return .math
    }

    public struct AlarmAudioOptions: Codable, Hashable, Sendable {
        public var backupSoundID: String
        public var rampSeconds: Int
        public var speaksLabel: Bool
        public var speaksTime: Bool

        public init(backupSoundID: String = "klaxon", rampSeconds: Int = 30,
                    speaksLabel: Bool = false, speaksTime: Bool = false) {
            self.backupSoundID = backupSoundID
            self.rampSeconds = rampSeconds
            self.speaksLabel = speaksLabel
            self.speaksTime = speaksTime
        }
    }

    public struct WakeCheckSettings: Codable, Hashable, Sendable {
        public var isEnabled: Bool
        public var delayMinutes: Int
        public var responseMinutes: Int

        public init(isEnabled: Bool = false, delayMinutes: Int = 5, responseMinutes: Int = 1) {
            self.isEnabled = isEnabled
            self.delayMinutes = delayMinutes
            self.responseMinutes = responseMinutes
        }
    }

    /// Separate from mission history: clearing history must not disarm a wake check.
    public struct PendingWakeCheck: Codable, Hashable, Identifiable, Sendable {
        public var id: String { parentKey }
        public let parentKey: String
        public let alarm: Alarm
        public let checkAt: Date
        public let deadline: Date

        public init(parentKey: String, alarm: Alarm, completedAt: Date) {
            let settings = alarm.wakeCheck ?? WakeCheckSettings()
            self.parentKey = parentKey
            self.alarm = alarm
            self.checkAt = completedAt.addingTimeInterval(TimeInterval(max(1, min(30, settings.delayMinutes)) * 60))
            self.deadline = checkAt.addingTimeInterval(TimeInterval(max(1, min(5, settings.responseMinutes)) * 60))
        }

        public struct PendingSnooze: Codable, Hashable, Sendable {
            public let alarm: Alarm
            public let parentKey: String
            public let round: Int
            public let fireDate: Date

            public init(alarm: Alarm, parentKey: String, round: Int, fireDate: Date) {
                self.alarm = alarm
                self.parentKey = parentKey
                self.round = round
                self.fireDate = fireDate
            }
        }

        public var checkKey: String { "\(parentKey)#wake-check" }
        public var reAlarmKey: String { "\(parentKey)#wake-realarm" }
    }

    /// `true` when the mission cannot be silently bypassed by pressing Stop.
    public var isGuarded: Bool {
        missionGuard.isEnabled && missionGuard.windowMinutes > 0 && mission.type != .none
    }
}

/// Built-in alarm sounds. All bundled locally so nothing is fetched at ring time (PRD SND-4).
public enum SoundLibrary {
    public struct Sound: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
        /// Filename including extension, as AlarmKit requires.
        public let fileName: String
        public let isGentle: Bool
    }

    public static let defaultSoundID = "radar"

    public static let all: [Sound] = [
        Sound(id: "radar", displayName: "Radar", fileName: "radar.wav", isGentle: false),
        Sound(id: "ascend", displayName: "Ascend", fileName: "ascend.wav", isGentle: true),
        Sound(id: "sunrise", displayName: "Sunrise", fileName: "sunrise.wav", isGentle: true),
        Sound(id: "chimes", displayName: "Chimes", fileName: "chimes.wav", isGentle: true),
        Sound(id: "klaxon", displayName: "Klaxon", fileName: "klaxon.wav", isGentle: false),
        Sound(id: "siren", displayName: "Siren", fileName: "siren.wav", isGentle: false),
        Sound(id: "insistent", displayName: "Insistent", fileName: "insistent.wav", isGentle: false)
    ]

    public static func sound(for id: String) -> Sound {
        all.first { $0.id == id } ?? all[0]
    }
}
