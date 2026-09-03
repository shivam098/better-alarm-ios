import Foundation

public enum MemoryModality: String, Codable, Hashable, CaseIterable, Sendable {
    case numbers, colors, shapes

    public var displayName: String {
        switch self {
        case .numbers: return "Numbers"
        case .colors: return "Colours"
        case .shapes: return "Shapes"
        }
    }
}

public struct MemorySequence: Hashable, Sendable {
    public let modality: MemoryModality
    /// The sequence the user must reproduce, in order.
    public let items: [String]
    /// How long the sequence is shown before it is hidden.
    public let displayDuration: TimeInterval
    /// Buttons offered during recall; always a superset of `items`.
    public let optionPool: [String]

    public var signature: String { "mem:\(modality.rawValue):\(items.joined(separator: "-"))" }

    public func matches(_ attempt: [String]) -> Bool { attempt == items }
}

/// Generates memory sequences (PRD M-03).
public enum MemorySequenceGenerator {

    private static let colorTokens = ["red", "blue", "green", "yellow", "purple", "orange"]
    private static let shapeTokens = ["●", "■", "▲", "★", "◆", "⬟"]

    public static func generate(
        difficulty: MissionDifficulty,
        modality: MemoryModality = .numbers,
        excluding history: Set<String> = [],
        using rng: inout SeededGenerator
    ) -> MemorySequence {
        var local = rng
        let sequence = UniqueChallengeFactory.make(
            excluding: history,
            signature: { (s: MemorySequence) in s.signature },
            produce: { build(difficulty: difficulty, modality: modality, using: &local) }
        )
        rng = local
        return sequence
    }

    private static func build(
        difficulty: MissionDifficulty,
        modality: MemoryModality,
        using rng: inout SeededGenerator
    ) -> MemorySequence {
        let length = sequenceLength(for: difficulty)
        let pool = optionPool(for: modality)

        var items: [String] = []
        var previous: String?
        for _ in 0..<length {
            // Avoid immediate repeats: "3 3" is a rendering problem, not a memory test.
            var candidates = pool
            if let previous { candidates.removeAll { $0 == previous } }
            let pick = candidates.randomElement(using: &rng) ?? pool[0]
            items.append(pick)
            previous = pick
        }

        return MemorySequence(
            modality: modality,
            items: items,
            displayDuration: displayDuration(for: difficulty),
            optionPool: pool
        )
    }

    static func sequenceLength(for difficulty: MissionDifficulty) -> Int {
        switch difficulty {
        case .veryEasy: return 3
        case .easy: return 4
        case .medium: return 5
        case .hard: return 7
        case .veryHard: return 9
        }
    }

    static func displayDuration(for difficulty: MissionDifficulty) -> TimeInterval {
        switch difficulty {
        case .veryEasy: return 2.5
        case .easy: return 2.0
        case .medium: return 1.5
        case .hard: return 1.1
        case .veryHard: return 0.8
        }
    }

    static func optionPool(for modality: MemoryModality) -> [String] {
        switch modality {
        case .numbers: return (1...6).map(String.init)
        case .colors: return colorTokens
        case .shapes: return shapeTokens
        }
    }
}
