import Foundation

public struct MissingSymbolPuzzle: Hashable, Sendable {
    public let rows: Int
    public let columns: Int
    /// Row-major grid. `nil` marks the cell the user must fill.
    public let grid: [String?]
    public let missingIndex: Int
    public let correctAnswer: String
    /// Shuffled choices, always containing `correctAnswer`.
    public let options: [String]

    public var signature: String {
        "sym:\(rows)x\(columns):\(grid.map { $0 ?? "_" }.joined()):\(correctAnswer)"
    }
}

/// Generates "find the missing symbol" puzzles (PRD M-02).
///
/// The grid is built from a rotating pattern so there is a real rule to spot,
/// and the puzzle is regenerated procedurally every time. Difficulty raises the
/// grid size, the number of options, and — the lever that actually matters —
/// how visually similar the distractors are to the answer.
public enum MissingSymbolGenerator {

    /// Families are grouped so distractors can be drawn from visually similar glyphs.
    private static let families: [[String]] = [
        ["▲", "▼", "◀", "▶", "◣", "◥"],
        ["●", "◍", "◉", "○", "◎", "⬤"],
        ["■", "□", "▣", "▤", "▥", "▦"],
        ["★", "☆", "✦", "✧", "✩", "✰"],
        ["◆", "◇", "◈", "⬖", "⬗", "⬘"],
        ["↑", "↓", "←", "→", "↖", "↘"]
    ]

    public static func generate(
        difficulty: MissionDifficulty,
        excluding history: Set<String> = [],
        using rng: inout SeededGenerator
    ) -> MissingSymbolPuzzle {
        var local = rng
        let puzzle = UniqueChallengeFactory.make(
            excluding: history,
            signature: { (p: MissingSymbolPuzzle) in p.signature },
            produce: { build(difficulty: difficulty, using: &local) }
        )
        rng = local
        return puzzle
    }

    private static func build(difficulty: MissionDifficulty, using rng: inout SeededGenerator) -> MissingSymbolPuzzle {
        let size = gridSize(for: difficulty)
        let optionCount = optionCount(for: difficulty)
        let useConfusableDistractors = difficulty >= .hard

        // The alphabet forming the pattern: one symbol per column.
        let primaryFamily = families.randomElement(using: &rng) ?? families[0]
        let alphabet = Array(primaryFamily.shuffled(using: &rng).prefix(size))

        // Rotating pattern: each row is the previous row shifted by `step`.
        // `step` is kept coprime with `size` so every row is a genuine rotation.
        let step = coprimeStep(for: size, using: &rng)

        var grid: [String?] = []
        for row in 0..<size {
            for column in 0..<size {
                grid.append(alphabet[(row * step + column) % size])
            }
        }

        let missingIndex = Int.random(in: 0..<(size * size), using: &rng)
        let correct = grid[missingIndex] ?? alphabet[0]
        grid[missingIndex] = nil

        // Distractors are drawn confusable-first, then topped up from the other
        // families. A single family cannot satisfy the harder option counts on
        // its own, and an under-filled set would quietly make the puzzle easier.
        let sameFamily = primaryFamily.filter { $0 != correct }.shuffled(using: &rng)
        let otherFamilies = families
            .flatMap { $0 }
            .filter { $0 != correct && !primaryFamily.contains($0) }
            .shuffled(using: &rng)

        let distractorPool = useConfusableDistractors
            ? sameFamily + otherFamilies
            : (sameFamily + otherFamilies).shuffled(using: &rng)

        // Built as an ordered array rather than a Set: Set iteration order varies
        // between processes, which would make a seeded puzzle irreproducible.
        var options: [String] = [correct]
        for candidate in distractorPool where options.count < optionCount {
            if !options.contains(candidate) { options.append(candidate) }
        }

        return MissingSymbolPuzzle(
            rows: size,
            columns: size,
            grid: grid,
            missingIndex: missingIndex,
            correctAnswer: correct,
            options: options.shuffled(using: &rng)
        )
    }

    static func gridSize(for difficulty: MissionDifficulty) -> Int {
        switch difficulty {
        case .veryEasy, .easy: return 3
        case .medium, .hard: return 4
        case .veryHard: return 5
        }
    }

    static func optionCount(for difficulty: MissionDifficulty) -> Int {
        switch difficulty {
        case .veryEasy: return 3
        case .easy: return 4
        case .medium: return 5
        case .hard: return 6
        case .veryHard: return 8
        }
    }

    /// A shift that is coprime with `size`, so rows never duplicate.
    private static func coprimeStep(for size: Int, using rng: inout SeededGenerator) -> Int {
        let candidates = (1..<size).filter { gcd($0, size) == 1 }
        guard !candidates.isEmpty else { return 1 }
        return candidates.randomElement(using: &rng) ?? 1
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}
