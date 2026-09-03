import SwiftUI
import AlarmyCore

/// The screen shown while an alarm is ringing.
///
/// Three deliberate omissions, each of which is the product:
///
/// * **No dismiss button.** The only ways out are completing the mission or
///   pressing the system Stop button — and the latter is recorded honestly and
///   leaves the Mission Guard chain armed.
/// * **No navigation.** Backgrounding or locking the phone does not resolve the
///   alarm and does not lose mission progress (PRD MEN-4).
/// * **No way to see the mission's answer.** Ever.
struct MissionRunnerView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @StateObject private var challenges = ChallengeHistoryStore()
    @StateObject private var interruptions = InterruptionMonitor()
    @StateObject private var audio = AlarmAudioSessionBox()

    let session: RingingSession

    @State private var stepIndex = 0
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.09, blue: 0.16), Color(red: 0.20, green: 0.11, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                header

                if let step = currentStep {
                    MissionStepView(
                        config: step,
                        challenges: challenges,
                        onSolved: advance,
                        onFailed: { failure in
                            Task { await coordinator.failMission(reason: failure) }
                        }
                    )
                    .id(stepIndex)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    ProgressView().tint(.white)
                }

                footer
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .onReceive(tick) { now = $0 }
        .onReceive(interruptions.events) { event in
            Task { await coordinator.noteAppLifecycle(event) }
        }
        .onAppear {
            audio.session.activate()
            audio.session.play(
                soundID: session.alarm.soundID,
                volume: session.alarm.volume,
                gentleRamp: session.alarm.gentleRamp
            )
        }
        .onDisappear { audio.session.stop() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 6) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 60, weight: .thin, design: .rounded))
                .monospacedDigit()

            Text(session.alarm.name)
                .font(.headline)
                .foregroundStyle(.secondary)

            if let substituted = session.substitutedFrom {
                Label(
                    "Switched from \(substituted.displayName)",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if interruptions.isOnCall {
                Label("Paused for a call — your alarm is still active", systemImage: "phone.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if interruptions.routeIsExternal {
                Label("Playing through a connected device", systemImage: "headphones")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if steps.count > 1 {
                Text("Mission \(stepIndex + 1) of \(steps.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let message = session.lastMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if canSnooze {
                Button {
                    Task { await coordinator.requestSnooze() }
                } label: {
                    Text(snoozeLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            } else if session.alarm.snooze.isEnabled {
                Text(snoozeBlockedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if session.alarm.isGuarded {
                Label(
                    "Mission Guard is on. Stopping without finishing brings this alarm back.",
                    systemImage: "shield.fill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Steps

    /// A combination mission runs its children in order; everything else is a
    /// single step that handles its own repetitions internally.
    private var steps: [MissionConfig] {
        session.mission.type == .combination && !session.mission.children.isEmpty
            ? session.mission.children
            : [session.mission]
    }

    private var currentStep: MissionConfig? {
        stepIndex < steps.count ? steps[stepIndex] : nil
    }

    private func advance() {
        if stepIndex + 1 < steps.count {
            withAnimation { stepIndex += 1 }
        } else {
            Task { await coordinator.completeMission() }
        }
    }

    // MARK: - Snooze

    private var canSnooze: Bool {
        SnoozePolicy.canSnooze(
            settings: session.alarm.snooze,
            snoozeCount: session.snoozeCount,
            missionSatisfied: session.missionSatisfied
        )
    }

    private var snoozeLabel: String {
        let minutes = SnoozePolicy.duration(for: session.alarm.snooze, snoozeCount: session.snoozeCount)
        if let remaining = SnoozePolicy.remaining(settings: session.alarm.snooze, snoozeCount: session.snoozeCount) {
            return "Snooze \(minutes) min · \(remaining) left"
        }
        return "Snooze \(minutes) min"
    }

    private var snoozeBlockedReason: String {
        if let remaining = SnoozePolicy.remaining(settings: session.alarm.snooze, snoozeCount: session.snoozeCount),
           remaining == 0 {
            return "No snoozes left. Finishing the mission is the only way to turn this off."
        }
        if session.alarm.snooze.costsMission && !session.missionSatisfied {
            return "Finish the mission first, then you can snooze."
        }
        return "Snooze isn't available for this alarm."
    }
}

/// `AlarmAudioSession` is not an `ObservableObject`; this keeps it alive for the
/// lifetime of the view without making the audio code know about SwiftUI.
@MainActor
final class AlarmAudioSessionBox: ObservableObject {
    let session = AlarmAudioSession()
}

/// Routes a mission config to its view. Adding a mission means adding one case
/// here and one view — the alarm system is untouched (PRD MEN-7).
struct MissionStepView: View {
    let config: MissionConfig
    @ObservedObject var challenges: ChallengeHistoryStore
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    var body: some View {
        switch config.type {
        case .none:
            SlideToStopMissionView(onSolved: onSolved)
        case .math:
            MathMissionView(config: config, challenges: challenges, onSolved: onSolved, onFailed: onFailed)
        case .missingSymbol:
            MissingSymbolMissionView(config: config, challenges: challenges, onSolved: onSolved, onFailed: onFailed)
        case .memory:
            MemoryMissionView(config: config, challenges: challenges, onSolved: onSolved, onFailed: onFailed)
        case .typing:
            TypingMissionView(config: config, challenges: challenges, onSolved: onSolved, onFailed: onFailed)
        case .shake:
            ShakeMissionView(config: config, onSolved: onSolved, onFailed: onFailed)
        case .steps:
            StepsMissionView(config: config, onSolved: onSolved, onFailed: onFailed)
        case .squat:
            SquatMissionView(config: config, onSolved: onSolved, onFailed: onFailed)
        case .photo:
            PhotoMissionView(config: config, onSolved: onSolved, onFailed: onFailed)
        case .qr:
            CodeMissionView(config: config, onSolved: onSolved, onFailed: onFailed)
        case .combination:
            // Flattened by the runner before it gets here.
            MathMissionView(config: config, challenges: challenges, onSolved: onSolved, onFailed: onFailed)
        }
    }
}

/// Practice mode. Identical mission views, but nothing is at stake (PRD MSN-8).
struct MissionPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var challenges = ChallengeHistoryStore()

    let config: MissionConfig
    @State private var solved = false

    var body: some View {
        NavigationStack {
            VStack {
                if solved {
                    ContentUnavailableView(
                        "Nice",
                        systemImage: "checkmark.circle.fill",
                        description: Text("That's what you'll do at \(config.difficulty.displayName.lowercased()) difficulty.")
                    )
                } else {
                    MissionStepView(
                        config: config,
                        challenges: challenges,
                        onSolved: { solved = true },
                        onFailed: { _ in }
                    )
                }
            }
            .padding()
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SlideToStopMissionView: View {
    let onSolved: () -> Void
    @State private var offset: CGFloat = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Slide to stop")
                .font(.title3)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                let travel = geometry.size.width - 76

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Circle()
                        .fill(.orange)
                        .frame(width: 64, height: 64)
                        .overlay(Image(systemName: "chevron.right").foregroundStyle(.white))
                        .offset(x: offset + 6)
                        .gesture(
                            DragGesture()
                                .onChanged { offset = max(0, min(travel, $0.translation.width)) }
                                .onEnded { _ in
                                    if offset > travel * 0.85 { onSolved() } else { withAnimation { offset = 0 } }
                                }
                        )
                }
            }
            .frame(height: 76)
            Spacer()
        }
    }
}
