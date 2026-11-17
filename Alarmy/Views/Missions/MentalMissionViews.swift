import SwiftUI
import AlarmyCore

// MARK: - Math (PRD M-01)

struct MathMissionView: View {
    let config: MissionConfig
    @ObservedObject var challenges: ChallengeHistoryStore
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    @State private var problem: MathProblem?
    @State private var entry = ""
    @State private var solvedCount = 0
    @State private var shake = false

    var body: some View {
        VStack(spacing: 24) {
            MissionProgressBar(progress: MissionProgress(current: solvedCount, target: config.targetCount, unit: "solved"))

            Spacer()

            Text(problem?.question ?? "")
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .modifier(ShakeEffect(animatableData: shake ? 1 : 0))

            Text(entry.isEmpty ? " " : entry)
                .font(.system(size: 40, weight: .medium, design: .monospaced))
                .frame(height: 52)
                .foregroundStyle(.orange)

            Spacer()

            NumberPad(
                entry: $entry,
                allowsNegative: true,
                onSubmit: submit
            )
        }
        .foregroundStyle(.white)
        .onAppear(perform: next)
    }

    private func next() {
        var rng = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970 * 1000) ^ UInt64(solvedCount &+ 1))
        let generated = MathMissionGenerator.generate(
            difficulty: config.difficulty,
            excluding: challenges.activeSignatures,
            using: &rng
        )
        challenges.record(generated.signature)
        problem = generated
        entry = ""
    }

    private func submit() {
        guard let problem, let value = Int(entry) else { return }

        if value == problem.answer {
            solvedCount += 1
            if solvedCount >= max(1, config.targetCount) {
                onSolved()
            } else {
                next()
            }
        } else {
            // A wrong answer costs a new problem, never the alarm (PRD MSN-INT-5).
            withAnimation(.default) { shake.toggle() }
            onFailed(.wrongAnswer)
            next()
        }
    }
}

// MARK: - Missing symbol (PRD M-02)

struct MissingSymbolMissionView: View {
    let config: MissionConfig
    @ObservedObject var challenges: ChallengeHistoryStore
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    @State private var puzzle: MissingSymbolPuzzle?
    @State private var solvedCount = 0

    var body: some View {
        VStack(spacing: 20) {
            MissionProgressBar(progress: MissionProgress(current: solvedCount, target: config.targetCount, unit: "solved"))

            Text("Which one is missing?")
                .font(.headline)
                .foregroundStyle(.secondary)

            if let puzzle {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: puzzle.columns)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(puzzle.grid.enumerated()), id: \.offset) { index, symbol in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.white.opacity(index == puzzle.missingIndex ? 0.05 : 0.12))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if let symbol {
                                    Text(symbol).font(.title)
                                } else {
                                    Image(systemName: "questionmark")
                                        .font(.title2)
                                        .foregroundStyle(.orange)
                                }
                            }
                    }
                }
                .padding(.horizontal)

                Spacer()

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(puzzle.options, id: \.self) { option in
                        Button { choose(option, in: puzzle) } label: {
                            Text(option)
                                .font(.title2)
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear(perform: next)
    }

    private func next() {
        var rng = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970 * 1000) ^ UInt64(solvedCount &+ 7))
        let generated = MissingSymbolGenerator.generate(
            difficulty: config.difficulty,
            excluding: challenges.activeSignatures,
            using: &rng
        )
        challenges.record(generated.signature)
        puzzle = generated
    }

    private func choose(_ option: String, in puzzle: MissingSymbolPuzzle) {
        if option == puzzle.correctAnswer {
            solvedCount += 1
            if solvedCount >= max(1, config.targetCount) { onSolved() } else { next() }
        } else {
            onFailed(.wrongAnswer)
            next()
        }
    }
}

// MARK: - Memory (PRD M-03)

struct MemoryMissionView: View {
    let config: MissionConfig
    @ObservedObject var challenges: ChallengeHistoryStore
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    private enum Phase { case memorising, recalling }

    @State private var sequence: MemorySequence?
    @State private var phase: Phase = .memorising
    @State private var attempt: [String] = []
    @State private var solvedCount = 0

    var body: some View {
        VStack(spacing: 22) {
            MissionProgressBar(progress: MissionProgress(current: solvedCount, target: config.targetCount, unit: "solved"))

            if let sequence {
                Text(phase == .memorising ? "Remember this" : "Repeat it back")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if phase == .memorising {
                    HStack(spacing: 12) {
                        ForEach(Array(sequence.items.enumerated()), id: \.offset) { _, item in
                            Text(item)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .frame(width: 58, height: 58)
                                .background(.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .task(id: sequence.signature) {
                        try? await Task.sleep(for: .seconds(sequence.displayDuration))
                        withAnimation { phase = .recalling }
                    }
                } else {
                    HStack(spacing: 10) {
                        ForEach(0..<sequence.items.count, id: \.self) { index in
                            Text(index < attempt.count ? attempt[index] : "")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .frame(width: 52, height: 52)
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    Spacer()

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(sequence.optionPool, id: \.self) { option in
                            Button { tap(option, in: sequence) } label: {
                                Text(option)
                                    .font(.title3)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("Clear") { attempt.removeAll() }
                        .font(.footnote)
                        .tint(.secondary)
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear(perform: next)
    }

    private func next() {
        var rng = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970 * 1000) ^ UInt64(solvedCount &+ 13))
        let generated = MemorySequenceGenerator.generate(
            difficulty: config.difficulty,
            excluding: challenges.activeSignatures,
            using: &rng
        )
        challenges.record(generated.signature)
        sequence = generated
        attempt = []
        phase = .memorising
    }

    private func tap(_ option: String, in sequence: MemorySequence) {
        attempt.append(option)
        guard attempt.count == sequence.items.count else { return }

        if sequence.matches(attempt) {
            solvedCount += 1
            if solvedCount >= max(1, config.targetCount) { onSolved() } else { next() }
        } else {
            onFailed(.sequenceMismatch)
            next()
        }
    }
}

// MARK: - Typing (PRD M-04)

struct TypingMissionView: View {
    let config: MissionConfig
    @ObservedObject var challenges: ChallengeHistoryStore
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    @State private var challenge: TypingChallenge?
    @State private var entry = ""
    @State private var solvedCount = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            MissionProgressBar(progress: MissionProgress(current: solvedCount, target: config.targetCount, unit: "typed"))

            Spacer()

            if let challenge {
                Text(challenge.phrase)
                    .font(.system(.title2, design: .serif))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("Type it here", text: $entry, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.title3, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .padding()
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    // Autocorrect and paste would do the waking up for you.
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .onChange(of: entry) { _, _ in checkCompletion(challenge) }

                if let mismatch = challenge.firstMismatchIndex(in: entry) {
                    Text("Check character \(mismatch + 1)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
        .foregroundStyle(.white)
        .onAppear {
            next()
            focused = true
        }
    }

    private func next() {
        var rng = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970 * 1000) ^ UInt64(solvedCount &+ 29))
        let generated = TypingPhraseProvider.generate(
            difficulty: config.difficulty,
            customSentences: config.customSentences ?? [],
            excluding: challenges.activeSignatures,
            using: &rng
        )
        challenges.record(generated.signature)
        challenge = generated
        entry = ""
    }

    private func checkCompletion(_ challenge: TypingChallenge) {
        guard challenge.matches(entry) else { return }
        solvedCount += 1
        if solvedCount >= max(1, config.targetCount) { onSolved() } else { next() }
    }
}

// MARK: - Shared chrome

struct MissionProgressBar: View {
    let progress: MissionProgress

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: progress.fraction)
                .tint(.orange)
            Text(progress.label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.label)
    }
}

struct NumberPad: View {
    @Binding var entry: String
    var allowsNegative = false
    let onSubmit: () -> Void

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "-", "0", "⌫"]

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(keys, id: \.self) { key in
                    Button { press(key) } label: {
                        Text(key)
                            .font(.title2.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(key == "-" && !allowsNegative)
                    .opacity(key == "-" && !allowsNegative ? 0.25 : 1)
                }
            }

            Button(action: onSubmit) {
                Text("Check")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(entry.isEmpty)
            .opacity(entry.isEmpty ? 0.4 : 1)
        }
    }

    private func press(_ key: String) {
        switch key {
        case "⌫":
            if !entry.isEmpty { entry.removeLast() }
        case "-":
            if entry.hasPrefix("-") { entry.removeFirst() } else { entry = "-" + entry }
        default:
            guard entry.count < 9 else { return }
            entry.append(key)
        }
    }
}

/// A small horizontal shake for a wrong answer: unmistakable, but not punitive.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 3), y: 0)
        )
    }
}
