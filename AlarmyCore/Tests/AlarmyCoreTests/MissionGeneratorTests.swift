import XCTest
@testable import AlarmyCore

/// The missions must be genuinely generative. A challenge that can be memorised
/// is a challenge a half-asleep user can complete without waking up.
final class MissionGeneratorTests: XCTestCase {

    func testCustomTypingUsesSavedSentencesAndIgnoresBlankLines() {
        var rng = SeededGenerator(seed: 17)
        let challenge = TypingPhraseProvider.generate(
            difficulty: .hard, customSentences: ["  ", "  Put both feet on the floor  "], using: &rng
        )
        XCTAssertEqual(challenge.phrase, "Put both feet on the floor")
        XCTAssertTrue(challenge.matches("put both feet on the floor"))
        let builtIn = TypingPhraseProvider.generate(difficulty: .easy, customSentences: ["\n"], using: &rng)
        XCTAssertFalse(builtIn.phrase.isEmpty)
    }

    func testCombinationNormalizationPreservesConfiguredChildrenAndTargets() {
        let photo = MissionConfig(type: .photo, targetCount: 2, referenceAssetIDs: ["target"])
        let typing = MissionConfig(type: .typing, difficulty: .hard, targetCount: 4, customSentences: ["Get up"])
        let config = MissionConfig(type: .combination, children: [photo, typing]).normalized()
        XCTAssertEqual(config.steps, [photo, typing])
        XCTAssertFalse(config.needsTarget)
        XCTAssertEqual(config.targetCount, 2)
        XCTAssertEqual(MissionConfig(type: .combination, children: []).normalized().steps.count, 2)
        XCTAssertTrue(MissionConfig(type: .combination, children: [photo, MissionConfig(type: .qr)]).needsTarget)
    }

    func testOldAlarmsAndMissionsDecodeWithoutNewSettings() throws {
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(Alarm())) as? [String: Any])
        json.removeValue(forKey: "audioOptions")
        json.removeValue(forKey: "wakeCheck")
        var mission = try XCTUnwrap(json["mission"] as? [String: Any])
        mission.removeValue(forKey: "customSentences")
        json["mission"] = mission
        let decoded = try JSONDecoder().decode(Alarm.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.audioOptions)
        XCTAssertNil(decoded.wakeCheck)
        XCTAssertNil(decoded.mission.customSentences)
        XCTAssertEqual(decoded.mission, .default)
    }

    func testWakeCheckPersistsSnapshotAndIndependentResponseDeadline() throws {
        let alarm = Alarm(wakeCheck: WakeCheckSettings(isEnabled: true, delayMinutes: 5, responseMinutes: 2))
        let completed = Date(timeIntervalSince1970: 1_000)
        let check = PendingWakeCheck(parentKey: "root", alarm: alarm, completedAt: completed)
        XCTAssertEqual(check.checkAt, completed.addingTimeInterval(300))
        XCTAssertEqual(check.deadline, completed.addingTimeInterval(420))
        let restored = try JSONDecoder().decode(PendingWakeCheck.self, from: JSONEncoder().encode(check))
        XCTAssertEqual(restored, check)
        XCTAssertNotEqual(restored.checkKey, restored.reAlarmKey)
        let followUp = AlarmOccurrence(alarmID: alarm.id, occurrenceKey: restored.checkKey,
                                       scheduledAt: restored.checkAt, outcome: .completed,
                                       missionType: .none, difficulty: .medium)
        XCTAssertEqual(StatisticsCalculator.summarise([followUp]).totalAlarms, 0)
    }

    // MARK: - Math

    func testMathBatchNeverRepeatsAProblem() {
        var rng = SeededGenerator(seed: 2026)
        let problems = MathMissionGenerator.generateBatch(count: 8, difficulty: .medium, using: &rng)

        XCTAssertEqual(problems.count, 8)
        XCTAssertEqual(Set(problems.map(\.signature)).count, 8)
    }

    func testMathHonoursRecentHistoryAcrossMornings() {
        var rng = SeededGenerator(seed: 7)
        var history = Set<String>()

        for _ in 0..<40 {
            let problem = MathMissionGenerator.generate(
                difficulty: .easy, excluding: history, using: &rng
            )
            XCTAssertFalse(
                history.contains(problem.signature),
                "A problem the user has already seen must not be served again"
            )
            history.insert(problem.signature)
        }
    }

    func testMathIsReproducibleForAGivenSeed() {
        var first = SeededGenerator(seed: 99)
        var second = SeededGenerator(seed: 99)

        XCTAssertEqual(
            MathMissionGenerator.generateBatch(count: 5, difficulty: .hard, using: &first),
            MathMissionGenerator.generateBatch(count: 5, difficulty: .hard, using: &second)
        )
    }

    func testMathAnswersAreNeverNegative() {
        var rng = SeededGenerator(seed: 5)
        for difficulty in MissionDifficulty.allCases {
            let problems = MathMissionGenerator.generateBatch(
                count: 30, difficulty: difficulty, using: &rng
            )
            for problem in problems {
                XCTAssertGreaterThanOrEqual(
                    problem.answer, 0,
                    "\(problem.question) produced a negative answer"
                )
                XCTAssertFalse(problem.question.isEmpty)
            }
        }
    }

    func testHarderMathProducesLargerAnswers() {
        var rng = SeededGenerator(seed: 11)
        let easy = MathMissionGenerator.generateBatch(count: 40, difficulty: .veryEasy, using: &rng)
        let hard = MathMissionGenerator.generateBatch(count: 40, difficulty: .hard, using: &rng)

        let easyMean = Double(easy.reduce(0) { $0 + $1.answer }) / Double(easy.count)
        let hardMean = Double(hard.reduce(0) { $0 + $1.answer }) / Double(hard.count)

        XCTAssertGreaterThan(hardMean, easyMean)
    }

    // MARK: - Missing symbol

    func testMissingSymbolPuzzleIsWellFormed() {
        var rng = SeededGenerator(seed: 3)

        for difficulty in MissionDifficulty.allCases {
            let puzzle = MissingSymbolGenerator.generate(difficulty: difficulty, using: &rng)
            let expectedSize = MissingSymbolGenerator.gridSize(for: difficulty)

            XCTAssertEqual(puzzle.rows, expectedSize)
            XCTAssertEqual(puzzle.grid.count, expectedSize * expectedSize)
            XCTAssertEqual(puzzle.grid.filter { $0 == nil }.count, 1, "Exactly one cell must be blank")
            XCTAssertNil(puzzle.grid[puzzle.missingIndex])
            XCTAssertTrue(
                puzzle.options.contains(puzzle.correctAnswer),
                "The answer must be among the offered options"
            )
            XCTAssertEqual(Set(puzzle.options).count, puzzle.options.count, "Options must be unique")
        }
    }

    func testMissingSymbolOfferedOptionsScaleWithDifficulty() {
        var rng = SeededGenerator(seed: 21)

        let easy = MissingSymbolGenerator.generate(difficulty: .veryEasy, using: &rng)
        let hard = MissingSymbolGenerator.generate(difficulty: .veryHard, using: &rng)

        XCTAssertEqual(easy.options.count, MissingSymbolGenerator.optionCount(for: .veryEasy))
        XCTAssertEqual(
            hard.options.count, MissingSymbolGenerator.optionCount(for: .veryHard),
            "Hard puzzles must fill their option count, not quietly fall back to fewer"
        )
        XCTAssertGreaterThan(hard.options.count, easy.options.count)
    }

    func testMissingSymbolPuzzlesDiffer() {
        var rng = SeededGenerator(seed: 4)
        var signatures = Set<String>()

        for _ in 0..<20 {
            let puzzle = MissingSymbolGenerator.generate(
                difficulty: .medium, excluding: signatures, using: &rng
            )
            XCTAssertFalse(signatures.contains(puzzle.signature))
            signatures.insert(puzzle.signature)
        }
    }

    // MARK: - Memory

    func testMemorySequenceLengthAndPaceFollowDifficulty() {
        var rng = SeededGenerator(seed: 8)

        let easy = MemorySequenceGenerator.generate(difficulty: .veryEasy, using: &rng)
        let hard = MemorySequenceGenerator.generate(difficulty: .veryHard, using: &rng)

        XCTAssertEqual(easy.items.count, 3)
        XCTAssertEqual(hard.items.count, 9)
        XCTAssertGreaterThan(easy.displayDuration, hard.displayDuration)
    }

    func testMemorySequenceAvoidsImmediateRepeats() {
        var rng = SeededGenerator(seed: 15)

        for _ in 0..<25 {
            let sequence = MemorySequenceGenerator.generate(difficulty: .hard, using: &rng)
            for index in 1..<sequence.items.count {
                XCTAssertNotEqual(
                    sequence.items[index], sequence.items[index - 1],
                    "Back-to-back repeats are a rendering puzzle, not a memory test"
                )
            }
        }
    }

    func testMemorySequenceMatchingIsOrderSensitive() {
        var rng = SeededGenerator(seed: 16)
        let sequence = MemorySequenceGenerator.generate(difficulty: .easy, using: &rng)

        XCTAssertTrue(sequence.matches(sequence.items))
        XCTAssertFalse(sequence.matches(sequence.items.reversed()))
        XCTAssertFalse(sequence.matches(Array(sequence.items.dropLast())))
        XCTAssertTrue(Set(sequence.items).isSubset(of: Set(sequence.optionPool)))
    }

    // MARK: - Typing

    func testTypingIsForgivingAboutCaseAndPunctuationButNotSpelling() {
        let challenge = TypingChallenge(phrase: "The kettle is boiling", caseSensitive: false)

        XCTAssertTrue(challenge.matches("the kettle is boiling"))
        XCTAssertTrue(challenge.matches("  The kettle   is boiling  "))
        XCTAssertTrue(challenge.matches("The kettle, is boiling!"))
        XCTAssertFalse(challenge.matches("The ketle is boiling"))
        XCTAssertFalse(challenge.matches("The kettle is"))
    }

    func testTypingCanBeStrictWhenConfigured() {
        let challenge = TypingChallenge(phrase: "The kettle is boiling", caseSensitive: true)
        XCTAssertFalse(challenge.matches("the kettle is boiling"))
        XCTAssertTrue(challenge.matches("The kettle is boiling"))
    }

    func testTypingReportsWhereTheUserWentWrong() {
        let challenge = TypingChallenge(phrase: "abcdef", caseSensitive: true)

        XCTAssertEqual(challenge.firstMismatchIndex(in: "abXdef"), 2)
        XCTAssertEqual(challenge.firstMismatchIndex(in: "abc"), 3)
        XCTAssertNil(challenge.firstMismatchIndex(in: "abcdef"))
    }

    func testTypingPhrasesGetLongerWithDifficulty() {
        XCTAssertLessThan(
            TypingPhraseProvider.targetLength(for: .veryEasy),
            TypingPhraseProvider.targetLength(for: .veryHard)
        )

        var rng = SeededGenerator(seed: 31)
        let challenge = TypingPhraseProvider.generate(difficulty: .medium, using: &rng)
        XCTAssertFalse(challenge.phrase.isEmpty)
    }

    // MARK: - Non-repeat history

    func testHistoryForgetsOldChallengesButRemembersRecentOnes() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        var history = RecentChallengeHistory()

        history.record("math:2 + 2", now: now.addingTimeInterval(-40 * 24 * 3600))
        history.record("math:3 + 3", now: now.addingTimeInterval(-2 * 24 * 3600))

        XCTAssertFalse(history.contains("math:2 + 2", now: now), "A 40-day-old problem may be reused")
        XCTAssertTrue(history.contains("math:3 + 3", now: now))
    }

    func testHistoryPrunesExpiredEntries() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        var history = RecentChallengeHistory()

        history.record("old", now: now.addingTimeInterval(-60 * 24 * 3600))
        history.record("new", now: now)
        history.prune(now: now)

        XCTAssertEqual(history.activeSignatures(now: now), ["new"])
    }

    func testUniqueFactoryGivesUpGracefullyRatherThanLockingTheUserOut() {
        // Every candidate is already in history: the user must still get a
        // challenge rather than an unresolvable alarm.
        let result = UniqueChallengeFactory.make(
            excluding: ["only"],
            maxAttempts: 5,
            signature: { $0 },
            produce: { "only" }
        )
        XCTAssertEqual(result, "only")
    }
}
