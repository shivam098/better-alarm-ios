import Foundation

public struct TypingChallenge: Hashable, Sendable {
    public let phrase: String
    /// When false, case and punctuation are forgiven but spelling is not.
    public let caseSensitive: Bool

    public var signature: String { "type:\(phrase)" }

    /// Compares an attempt against the phrase under the configured strictness.
    public func matches(_ attempt: String) -> Bool {
        TypingChallenge.normalise(attempt, caseSensitive: caseSensitive)
            == TypingChallenge.normalise(phrase, caseSensitive: caseSensitive)
    }

    /// Index of the first differing character, for inline feedback.
    public func firstMismatchIndex(in attempt: String) -> Int? {
        let target = Array(TypingChallenge.normalise(phrase, caseSensitive: caseSensitive))
        let typed = Array(TypingChallenge.normalise(attempt, caseSensitive: caseSensitive))
        for index in 0..<min(target.count, typed.count) where target[index] != typed[index] {
            return index
        }
        return typed.count < target.count ? typed.count : nil
    }

    static func normalise(_ text: String, caseSensitive: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse runs of whitespace so a double space is not a failure.
        result = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !caseSensitive {
            result = result.lowercased()
            result.removeAll { $0.isPunctuation }
        }
        return result
    }
}

/// Supplies typing phrases (PRD M-04).
///
/// Phrases are original, deliberately mundane, and long enough that completing
/// one while half asleep takes real attention. Paste, autocorrect, predictive
/// text and dictation are disabled by the view that presents them.
public enum TypingPhraseProvider {

    static let phrases: [String] = [
        "The kettle is already boiling in the kitchen downstairs",
        "Nine parcels were left beside the blue recycling bin",
        "My bus leaves in forty minutes and it will not wait",
        "Twelve sparrows landed on the fence outside the window",
        "The bread has been in the toaster for far too long",
        "Please remember to water the plants before you leave",
        "A quiet morning is worth more than an extra ten minutes",
        "The laundry finished its cycle at half past six today",
        "Seventeen emails arrived while everyone else was asleep",
        "Cold water on the face works better than another alarm",
        "The train timetable changed again at the start of March",
        "There are four clean mugs left in the top left cupboard",
        "Walking to the corner shop takes about eleven minutes",
        "The neighbour's dog begins barking at exactly seven",
        "Someone left the hallway light on for the entire night",
        "Breakfast tastes considerably better when you are upright",
        "Thirty seconds of standing up defeats most snooze buttons",
        "The window needs closing before the rain arrives later",
        "My keys are usually hiding underneath yesterday's jacket",
        "A short walk outside resets almost any difficult morning",
        "The calendar says today is busier than it looks on paper",
        "Six oranges and a loaf of bread are on the shopping list",
        "Turning the heating on early makes leaving bed much easier",
        "The pavement outside is wet but the sky is finally clear"
    ]

    public static func generate(
        difficulty: MissionDifficulty,
        caseSensitive: Bool = false,
        excluding history: Set<String> = [],
        using rng: inout SeededGenerator
    ) -> TypingChallenge {
        let target = targetLength(for: difficulty)

        // Prefer phrases close to the target length for this difficulty.
        let ranked = phrases.sorted {
            abs($0.count - target) < abs($1.count - target)
        }
        let shortlist = Array(ranked.prefix(max(6, phrases.count / 2)))

        var local = rng
        let challenge = UniqueChallengeFactory.make(
            excluding: history,
            signature: { (c: TypingChallenge) in c.signature },
            produce: {
                TypingChallenge(
                    phrase: shortlist.randomElement(using: &local) ?? phrases[0],
                    caseSensitive: caseSensitive
                )
            }
        )
        rng = local
        return challenge
    }

    static func targetLength(for difficulty: MissionDifficulty) -> Int {
        switch difficulty {
        case .veryEasy: return 25
        case .easy: return 35
        case .medium: return 45
        case .hard: return 55
        case .veryHard: return 62
        }
    }
}
