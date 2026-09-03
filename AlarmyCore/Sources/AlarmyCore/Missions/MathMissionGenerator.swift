import Foundation

public struct MathProblem: Hashable, Codable, Sendable {
    public let question: String
    public let answer: Int

    public init(question: String, answer: Int) {
        self.question = question
        self.answer = answer
    }

    /// Identity used for the 30-day non-repeat rule.
    public var signature: String { "math:\(question)" }
}

/// Generates math problems (PRD M-01).
///
/// Problems are produced procedurally and checked against the user's recent
/// history, so the same question is never served twice within the retention
/// window and cannot be memorised.
public enum MathMissionGenerator {

    public static func generate(
        difficulty: MissionDifficulty,
        excluding history: Set<String> = [],
        using rng: inout SeededGenerator
    ) -> MathProblem {
        var local = rng
        let problem = UniqueChallengeFactory.make(
            excluding: history,
            signature: { (p: MathProblem) in p.signature },
            produce: { build(difficulty: difficulty, using: &local) }
        )
        rng = local
        return problem
    }

    /// A fresh batch, unique within itself as well as against history.
    public static func generateBatch(
        count: Int,
        difficulty: MissionDifficulty,
        excluding history: Set<String> = [],
        using rng: inout SeededGenerator
    ) -> [MathProblem] {
        var seen = history
        var problems: [MathProblem] = []
        for _ in 0..<max(1, count) {
            let problem = generate(difficulty: difficulty, excluding: seen, using: &rng)
            seen.insert(problem.signature)
            problems.append(problem)
        }
        return problems
    }

    private static func build(difficulty: MissionDifficulty, using rng: inout SeededGenerator) -> MathProblem {
        switch difficulty {
        case .veryEasy:
            let a = Int.random(in: 1...9, using: &rng)
            let b = Int.random(in: 1...9, using: &rng)
            return MathProblem(question: "\(a) + \(b)", answer: a + b)

        case .easy:
            let a = Int.random(in: 10...49, using: &rng)
            let b = Int.random(in: 2...9, using: &rng)
            if Bool.random(using: &rng) {
                return MathProblem(question: "\(a) + \(b)", answer: a + b)
            }
            // Keep the result non-negative — negative answers are a keypad problem,
            // not a wake-up problem.
            return MathProblem(question: "\(a) − \(b)", answer: a - b)

        case .medium:
            switch Int.random(in: 0...2, using: &rng) {
            case 0:
                let a = Int.random(in: 12...89, using: &rng)
                let b = Int.random(in: 11...89, using: &rng)
                return MathProblem(question: "\(a) + \(b)", answer: a + b)
            case 1:
                let a = Int.random(in: 40...99, using: &rng)
                let b = Int.random(in: 11...39, using: &rng)
                return MathProblem(question: "\(a) − \(b)", answer: a - b)
            default:
                let a = Int.random(in: 3...9, using: &rng)
                let b = Int.random(in: 11...29, using: &rng)
                return MathProblem(question: "\(a) × \(b)", answer: a * b)
            }

        case .hard:
            switch Int.random(in: 0...2, using: &rng) {
            case 0:
                let a = Int.random(in: 120...899, using: &rng)
                let b = Int.random(in: 110...499, using: &rng)
                return MathProblem(question: "\(a) + \(b)", answer: a + b)
            case 1:
                let a = Int.random(in: 300...999, using: &rng)
                let b = Int.random(in: 110...299, using: &rng)
                return MathProblem(question: "\(a) − \(b)", answer: a - b)
            default:
                let a = Int.random(in: 11...39, using: &rng)
                let b = Int.random(in: 11...29, using: &rng)
                return MathProblem(question: "\(a) × \(b)", answer: a * b)
            }

        case .veryHard:
            // Multi-step, exercising order of operations.
            let a = Int.random(in: 11...49, using: &rng)
            let b = Int.random(in: 3...12, using: &rng)
            let c = Int.random(in: 3...9, using: &rng)
            if Bool.random(using: &rng) {
                return MathProblem(question: "\(a) + \(b) × \(c)", answer: a + b * c)
            }
            return MathProblem(question: "(\(a) + \(b)) × \(c)", answer: (a + b) * c)
        }
    }
}
