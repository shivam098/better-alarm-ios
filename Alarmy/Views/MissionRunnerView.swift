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

    let initialSession: RingingSession

    init(session: RingingSession) { self.initialSession = session }

    private var session: RingingSession { coordinator.session ?? initialSession }

    @State private var stepIndex = 0
    @State private var now = Date()
    @State private var fallback: MissionConfig?

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

                if session.occurrenceKey.hasSuffix("#wake-check") {
                    VStack(spacing: 20) {
                        Text("Still awake?").font(.largeTitle.bold())
                        Text("Confirm before the response window ends, or your alarm will ring again.")
                        Button("I'm awake") { Task { await coordinator.completeMission() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: .infinity)
                } else if session.missionSatisfied {
                    Button("Retry finishing") { Task { await coordinator.completeMission() } }
                        .buttonStyle(.borderedProminent)
                        .frame(maxHeight: .infinity)
                } else if let step = currentStep {
                    let completedStep = stepIndex
                    MissionStepView(
                        config: step,
                        challenges: challenges,
                        onSolved: { advance(completedStep: completedStep) },
                        onFailed: { failure in
                            Task { await coordinator.failMission(reason: failure) }
                            if case .sensorUnavailable = failure { useFallback() }
                        },
                        onFallback: useFallback
                    )
                    .id("\(stepIndex)-\(step.type.rawValue)")
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
            if event == .callEnded { audio.session.resume() }
            if event == .callStarted { audio.session.pause() }
            if event == .audioRouteChanged && interruptions.routeIsExternal { audio.session.routeToSpeaker() }
        }
        .onAppear {
            audio.session.play(alarm: session.alarm, usesBackup: session.occurrenceKey.contains("#wd") || session.occurrenceKey.hasSuffix("#wake-realarm")) {
                coordinator.banner = $0
            }
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
            if let message = coordinator.banner {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
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
        session.mission.normalized().steps
    }

    private var currentStep: MissionConfig? {
        stepIndex < steps.count ? (fallback ?? steps[stepIndex]) : nil
    }

    private func advance(completedStep: Int) {
        guard completedStep == stepIndex, !session.missionSatisfied else { return }
        fallback = nil
        if stepIndex + 1 < steps.count {
            withAnimation { stepIndex += 1 }
        } else {
            Task { await coordinator.completeMission() }
        }

    }

    // MARK: - Snooze

    private func useFallback() {
        guard let step = currentStep else { return }
        fallback = MissionConfig(type: session.alarm.resolvedFallback(excluding: Set(MissionPermission.allPermissions)),
                                 difficulty: step.difficulty)
        Task { await coordinator.noteFallback(from: step.type, to: fallback?.type ?? .math) }
    }

    private var canSnooze: Bool {
        !session.occurrenceKey.contains("#wd") && !session.occurrenceKey.contains("#wake-")
        && !session.snoozeAfterMission && SnoozePolicy.canSnooze(
            settings: session.alarm.snooze,
            snoozeCount: session.snoozeCount,
            missionSatisfied: true
        )
    }

    private var snoozeLabel: String {
        if session.alarm.snooze.costsMission && !session.missionSatisfied {
            return "Complete mission to snooze"
        }
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
    let onFallback: () -> Void

    var body: some View {
        MissionPermissionGate(permissions: config.requiredPermissions, onFallback: onFallback) {
            VStack {
                missionBody
                if !config.requiredPermissions.isEmpty {
                    Button("Use a backup mission", action: onFallback)
                        .font(.footnote)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var missionBody: some View {
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
            PhotoMissionView(config: config, onSolved: onSolved, onFailed: onFailed, onFallback: onFallback)
        case .qr:
            CodeMissionView(config: config, onSolved: onSolved, onFailed: onFailed, onFallback: onFallback)
        case .combination:
            ContentUnavailableView("Invalid mission sequence", systemImage: "exclamationmark.triangle")
        }
    }
}

/// Practice mode. Identical mission views, but nothing is at stake (PRD MSN-8).
struct MissionPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var challenges = ChallengeHistoryStore()

    let config: MissionConfig
    @State private var solved = false
    @State private var index = 0
    @State private var fallback: MissionConfig?
    @State private var message: String?

    private var steps: [MissionConfig] { config.normalized().steps }

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
                    let completedStep = index
                    MissionStepView(
                        config: fallback ?? steps[index],
                        challenges: challenges,
                        onSolved: {
                            guard completedStep == index, !solved else { return }
                            fallback = nil
                            if index + 1 < steps.count { index += 1 } else { solved = true }
                        },
                        onFailed: {
                            message = $0.userMessage
                            if case .sensorUnavailable = $0 { fallback = .default }
                        },
                        onFallback: { fallback = .default }
                    )
                    .id("\(index)-\((fallback ?? steps[index]).type.rawValue)")
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
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
