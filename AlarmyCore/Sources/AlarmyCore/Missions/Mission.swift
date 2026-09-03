import Foundation

/// Live progress for a running mission, shown both in-app and in the Live
/// Activity: "27/50 steps", "6/10 squats" (PRD UX-1).
public struct MissionProgress: Hashable, Sendable {
    public let current: Int
    public let target: Int
    public let unit: String

    public init(current: Int, target: Int, unit: String) {
        self.current = current
        self.target = target
        self.unit = unit
    }

    public var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1.0, Double(current) / Double(target))
    }

    public var isComplete: Bool { target > 0 && current >= target }

    public var label: String { "\(current)/\(target) \(unit)" }

    public static let none = MissionProgress(current: 0, target: 0, unit: "")
}

/// Why a mission attempt failed. The app must always be able to explain itself
/// rather than showing a bare "Failed" (PRD M-08, UX-6).
public enum MissionFailure: Hashable, Sendable {
    case wrongAnswer
    case sequenceMismatch
    case typingMismatch
    case targetMismatch(String)
    case looksLikeAScreen
    case tooDark
    case notRecognised(String)
    case sensorUnavailable(MissionPermission)
    case movementNotDetected
    case mechanicalMotionDetected

    public var userMessage: String {
        switch self {
        case .wrongAnswer:
            return "Not quite — here's a new one."
        case .sequenceMismatch:
            return "That wasn't the sequence. Try this one."
        case .typingMismatch:
            return "There's a typo — check the highlighted characters."
        case .targetMismatch(let target):
            return "That doesn't look like your \(target). Try getting closer."
        case .looksLikeAScreen:
            return "This looks like a photo of a screen. Point the camera at the real thing."
        case .tooDark:
            return "Too dark to tell. Turn on a light and try again."
        case .notRecognised(let what):
            return "Couldn't recognise \(what). Try again."
        case .sensorUnavailable(let permission):
            return "\(permission.displayName) isn't available, so we'll switch missions."
        case .movementNotDetected:
            return "We couldn't detect that movement yet."
        case .mechanicalMotionDetected:
            return "That motion looked automated. Try moving naturally."
        }
    }
}

/// The plug-in shape every mission conforms to.
///
/// New missions can be added without touching the alarm system (PRD MEN-7):
/// the runner only ever talks to this protocol.
public protocol MissionRunning: AnyObject {
    var type: MissionType { get }
    var progress: MissionProgress { get }
    /// Permissions that must be granted before `start()` is called.
    var requiredPermissions: Set<MissionPermission> { get }

    func start()
    func cancel()
}

/// Catalogue entry powering the mission picker.
public struct MissionDescriptor: Identifiable, Hashable, Sendable {
    public var id: MissionType { type }
    public let type: MissionType
    public let summary: String
    /// 1–5 meter shown on the mission card (PRD UX-9).
    public let intensity: Int
    public let symbolName: String

    public var displayName: String { type.displayName }
    public var category: MissionCategory { type.category }
    public var permissions: Set<MissionPermission> { type.requiredPermissions }
}

/// The complete mission library.
///
/// Every entry is free and usable. There is no locked mission and no
/// visible-but-paywalled entry (PRD MON-1 / MON-2).
public enum MissionLibrary {
    public static let all: [MissionDescriptor] = [
        MissionDescriptor(
            type: .none,
            summary: "Slide to stop. No mission — for alarms you don't need to fight.",
            intensity: 1,
            symbolName: "arrow.right.circle"
        ),
        MissionDescriptor(
            type: .math,
            summary: "Solve problems. New ones every time, never repeated.",
            intensity: 2,
            symbolName: "function"
        ),
        MissionDescriptor(
            type: .missingSymbol,
            summary: "Spot the element missing from a pattern.",
            intensity: 2,
            symbolName: "square.grid.3x3"
        ),
        MissionDescriptor(
            type: .memory,
            summary: "Watch a sequence, then repeat it back.",
            intensity: 3,
            symbolName: "brain.head.profile"
        ),
        MissionDescriptor(
            type: .typing,
            summary: "Type a phrase exactly. No paste, no autocorrect.",
            intensity: 3,
            symbolName: "keyboard"
        ),
        MissionDescriptor(
            type: .shake,
            summary: "Shake the phone until you're awake.",
            intensity: 3,
            symbolName: "iphone.gen3.radiowaves.left.and.right"
        ),
        MissionDescriptor(
            type: .steps,
            summary: "Get out of bed and walk. Steps are counted live.",
            intensity: 4,
            symbolName: "figure.walk"
        ),
        MissionDescriptor(
            type: .squat,
            summary: "Do squats. Reps counted by the camera.",
            intensity: 5,
            symbolName: "figure.strengthtraining.functional"
        ),
        MissionDescriptor(
            type: .photo,
            summary: "Photograph something across the room.",
            intensity: 4,
            symbolName: "camera"
        ),
        MissionDescriptor(
            type: .qr,
            summary: "Scan a code you've stuck somewhere far from bed.",
            intensity: 4,
            symbolName: "qrcode.viewfinder"
        ),
        MissionDescriptor(
            type: .combination,
            summary: "Chain missions together. Maximum resistance.",
            intensity: 5,
            symbolName: "square.stack.3d.up"
        )
    ]

    public static func descriptor(for type: MissionType) -> MissionDescriptor {
        all.first { $0.type == type } ?? all[1]
    }

    /// Suggests a mission the user has not tried (PRD UX-5).
    public static func suggestion(excluding used: Set<MissionType>) -> MissionDescriptor? {
        all.first { $0.type != .none && !used.contains($0.type) }
    }
}
