import Foundation

// MARK: - Mission type

/// The full mission library. Every case is available to every user for free
/// (PRD MON-1 … MON-5): there is no premium tier and no locked mission.
public enum MissionType: String, Codable, Hashable, CaseIterable, Sendable {
    case none
    case math
    case missingSymbol
    case memory
    case typing
    case shake
    case steps
    case squat
    case photo
    case qr
    case combination

    public var displayName: String {
        switch self {
        case .none: return "Slide to stop"
        case .math: return "Math"
        case .missingSymbol: return "Find the Missing Symbol"
        case .memory: return "Memory"
        case .typing: return "Typing"
        case .shake: return "Shake"
        case .steps: return "Walking"
        case .squat: return "Squats"
        case .photo: return "Photo"
        case .qr: return "Barcode / QR"
        case .combination: return "Combination"
        }
    }

    public var category: MissionCategory {
        switch self {
        case .none: return .none
        case .math, .memory, .typing: return .mental
        case .missingSymbol: return .visual
        case .shake, .steps, .squat: return .physical
        case .photo, .qr: return .location
        case .combination: return .mixed
        }
    }

    /// Permissions this mission needs. A basic alarm needs none of these
    /// beyond the always-required alarm scheduling permission (PRD PRM-1).
    public var requiredPermissions: Set<MissionPermission> {
        switch self {
        case .none, .math, .missingSymbol, .memory, .typing:
            return []
        case .shake:
            return [.motion]
        case .steps:
            return [.motionFitness]
        case .squat:
            return [.camera, .motion]
        case .photo, .qr:
            return [.camera]
        case .combination:
            return []
        }
    }

    /// Whether the mission requires the user to physically move (PRD SAF-2/SAF-3).
    public var isPhysical: Bool {
        switch self {
        case .shake, .steps, .squat: return true
        default: return false
        }
    }

    /// Ordered substitutes offered when a permission or sensor is unavailable
    /// (PRD PRM-4 / PRM-5). Every chain terminates in a mission that needs no
    /// permissions at all, so an alarm can never become uncompletable (PRM-7).
    public var fallbackChain: [MissionType] {
        switch self {
        case .photo: return [.qr, .typing, .math]
        case .qr: return [.typing, .math]
        case .squat: return [.steps, .shake, .math]
        case .steps: return [.shake, .math]
        case .shake: return [.math]
        case .combination: return [.math]
        case .none, .math, .missingSymbol, .memory, .typing: return [.math]
        }
    }

    /// Base hardness weight used when merging overlapping alarms (PRD INT-12).
    var baseHardness: Int {
        switch self {
        case .none: return 0
        case .math: return 2
        case .missingSymbol: return 2
        case .memory: return 3
        case .typing: return 3
        case .shake: return 3
        case .steps: return 4
        case .squat: return 5
        case .photo: return 5
        case .qr: return 5
        case .combination: return 6
        }
    }
}

public enum MissionCategory: String, Codable, Hashable, Sendable {
    case none, mental, visual, physical, location, mixed

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .mental: return "Mental"
        case .visual: return "Visual"
        case .physical: return "Physical"
        case .location: return "Location"
        case .mixed: return "Mixed"
        }
    }
}

public enum MissionPermission: String, Codable, Hashable, Sendable {
    case camera
    case motion
    case motionFitness

    public var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .motion: return "Motion"
        case .motionFitness: return "Motion & Fitness"
        }
    }

    /// Plain-language reason shown *before* the system prompt (PRD PRM-3).
    public var rationale: String {
        switch self {
        case .camera:
            return "Used only while you are completing a camera mission. Images are checked on your device and never uploaded."
        case .motion:
            return "Used only while a motion mission is running, to confirm the movement actually happened."
        case .motionFitness:
            return "Used only while a walking mission is running, to count your steps."
        }
    }
}

public enum MissionDifficulty: Int, Codable, Hashable, CaseIterable, Comparable, Sendable {
    case veryEasy = 1
    case easy = 2
    case medium = 3
    case hard = 4
    case veryHard = 5

    public static func < (lhs: MissionDifficulty, rhs: MissionDifficulty) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .veryEasy: return "Very easy"
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        case .veryHard: return "Very hard"
        }
    }

    /// One step harder, capped. Used by escalation (PRD REL-2).
    public func harder() -> MissionDifficulty {
        MissionDifficulty(rawValue: Swift.min(rawValue + 1, MissionDifficulty.veryHard.rawValue)) ?? self
    }
}

// MARK: - Mission configuration

/// Per-alarm mission settings.
///
/// `children` is only populated for `.combination`, which chains 2–5 missions
/// (PRD M-10).
public struct MissionConfig: Codable, Hashable, Sendable {
    public var type: MissionType
    public var difficulty: MissionDifficulty
    /// Repetition target: problem count, step count, shake count, squat reps, codes to scan.
    public var targetCount: Int
    /// Identifiers of locally stored reference assets (photo targets, registered QR payload hashes).
    public var referenceAssetIDs: [String]
    public var children: [MissionConfig]

    public init(
        type: MissionType = .math,
        difficulty: MissionDifficulty = .medium,
        targetCount: Int? = nil,
        referenceAssetIDs: [String] = [],
        children: [MissionConfig] = []
    ) {
        self.type = type
        self.difficulty = difficulty
        self.targetCount = targetCount ?? MissionConfig.defaultTargetCount(for: type)
        self.referenceAssetIDs = referenceAssetIDs
        self.children = children
    }

    public static let `default` = MissionConfig(type: .math, difficulty: .medium, targetCount: 3)

    public static func defaultTargetCount(for type: MissionType) -> Int {
        switch type {
        case .none: return 0
        case .math: return 3
        case .missingSymbol: return 3
        case .memory: return 3
        case .typing: return 1
        case .shake: return 30
        case .steps: return 30
        case .squat: return 10
        case .photo: return 1
        case .qr: return 1
        case .combination: return 2
        }
    }

    /// Allowed range for `targetCount`, enforced by the editor so a user cannot
    /// configure something unsafe or uncompletable (PRD SAF-5).
    public static func targetRange(for type: MissionType) -> ClosedRange<Int> {
        switch type {
        case .none: return 0...0
        case .math, .missingSymbol, .memory: return 1...10
        case .typing: return 1...5
        case .shake: return 10...200
        case .steps: return 10...500
        case .squat: return 3...50
        case .photo: return 1...3
        case .qr: return 1...3
        case .combination: return 2...5
        }
    }

    public var requiredPermissions: Set<MissionPermission> {
        if type == .combination {
            return children.reduce(into: Set<MissionPermission>()) { $0.formUnion($1.requiredPermissions) }
        }
        return type.requiredPermissions
    }

    /// Score used to pick the hardest mission when alarms are merged (PRD INT-12).
    public var hardnessScore: Int {
        if type == .combination {
            return type.baseHardness + children.reduce(0) { $0 + $1.hardnessScore }
        }
        return type.baseHardness * 10 + difficulty.rawValue
    }

    /// Returns a copy escalated one difficulty step (PRD REL-2).
    public func escalated() -> MissionConfig {
        var copy = self
        copy.difficulty = difficulty.harder()
        copy.children = children.map { $0.escalated() }
        return copy
    }

    /// Clamps `targetCount` into the legal range for the current type.
    public func normalized() -> MissionConfig {
        var copy = self
        let range = MissionConfig.targetRange(for: type)
        copy.targetCount = Swift.min(Swift.max(targetCount, range.lowerBound), range.upperBound)
        if copy.type != .combination { copy.children = [] }
        return copy
    }
}
