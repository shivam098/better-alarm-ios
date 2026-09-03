import Foundation
import SwiftUI
import AppIntents
import AlarmKit
import AlarmyCore
import ActivityKit

// ============================================================================
//  THE ONLY FILE IN THIS PROJECT THAT IMPORTS AlarmKit.
//
//  AlarmKit shipped in iOS 26 and its API has already moved once (see the
//  `makeAlert` note below). Every AlarmKit symbol is confined here so that if
//  Apple changes a signature, the fix is one file — not a project-wide hunt.
//
//  Naming hazard: AlarmKit also declares a type called `Alarm`. Ours is
//  `AlarmyCore.Alarm`. Everything in this file is fully qualified.
// ============================================================================

/// Real AlarmKit-backed scheduling.
///
/// An `actor` because AlarmKit's manager is not `Sendable` and we mutate a small
/// identifier cache alongside it.
actor AlarmKitScheduler: SystemAlarmScheduling {

    /// `AlarmManager` is not `Sendable`; the actor provides the isolation that
    /// the type itself does not.
    nonisolated(unsafe) private let manager = AlarmManager.shared

    private let tintColor: Color

    init(tintColor: Color = .orange) {
        self.tintColor = tintColor
    }

    // MARK: - Authorization

    func authorizationStatus() async -> SystemAlarmAuthorization {
        switch manager.authorizationState {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    @discardableResult
    func requestAuthorization() async -> SystemAlarmAuthorization {
        do {
            let state = try await manager.requestAuthorization()
            switch state {
            case .authorized: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        } catch {
            return .denied
        }
    }

    // MARK: - Scheduling

    func schedule(_ requests: [SystemAlarmRequest]) async throws {
        guard await authorizationStatus() == .authorized else {
            throw SystemAlarmError.notAuthorized
        }

        for request in requests where request.fireDate > Date() {
            do {
                _ = try await manager.schedule(
                    id: request.id,
                    configuration: configuration(for: request)
                )
            } catch {
                // One bad alarm must not abort the whole chain: a missing
                // watchdog is far better than an unscheduled primary alarm.
                AlarmyLog.scheduling.error(
                    "Failed to schedule \(request.occurrenceKey): \(error.localizedDescription)"
                )
                if case .primary = request.role {
                    throw SystemAlarmError.schedulingFailed(error.localizedDescription)
                }
            }
        }
    }

    func cancel(ids: [UUID]) async {
        for id in ids {
            // `cancel` is synchronous and throwing; it throws for unknown ids,
            // which is a normal outcome during reconciliation.
            try? manager.cancel(id: id)
        }
    }

    func stopRinging(id: UUID) async {
        try? await manager.stop(id: id)
    }

    func pendingIdentifiers() async -> Set<UUID> {
        // `alarms` is a throwing property.
        guard let alarms = try? manager.alarms else { return [] }
        return Set(alarms.map(\.id))
    }

    nonisolated func events() -> AsyncStream<SystemAlarmEvent> {
        AsyncStream { continuation in
            let task = Task {
                var alerting: Set<UUID> = []

                for await snapshot in manager.alarmUpdates {
                    let current = Set(snapshot.filter { $0.state == .alerting }.map(\.id))
                    let known = Set(snapshot.map(\.id))

                    for id in current.subtracting(alerting) {
                        continuation.yield(.alerting(id: id))
                    }
                    for id in alerting.subtracting(known) {
                        continuation.yield(.ended(id: id))
                    }
                    alerting = current
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Configuration assembly

    private func configuration(
        for request: SystemAlarmRequest
    ) -> AlarmManager.AlarmConfiguration<AlarmyMetadata> {

        let usesBuiltInCountdown = request.mission.type == .none && request.allowSnooze

        let attributes = AlarmAttributes<AlarmyMetadata>(
            presentation: AlarmPresentation(alert: makeAlert(for: request, countdown: usesBuiltInCountdown)),
            metadata: AlarmyMetadata(request: request),
            tintColor: tintColor
        )

        return AlarmManager.AlarmConfiguration(
            countdownDuration: usesBuiltInCountdown
                ? Alarm.CountdownDuration(preAlert: nil, postAlert: TimeInterval(request.snoozeMinutes * 60))
                : nil,
            schedule: .fixed(request.fireDate),
            attributes: attributes,
            // Stop runs OUR code. This is what makes it possible to record a
            // dismissal as `dismissedUnverified` instead of a completion, and to
            // leave the Mission Guard chain armed (PRD §6.2, MEN-1).
            stopIntent: StopAlarmIntent(occurrenceKey: request.occurrenceKey),
            secondaryIntent: StartMissionIntent(occurrenceKey: request.occurrenceKey),
            sound: alertSound(for: request.soundID)
        )
    }

    /// Builds the alert.
    ///
    /// KNOWN API VARIANCE: iOS 26.1 changed `AlarmPresentation.Alert`'s
    /// initializer. If the build fails on this call, that is the cause — adjust
    /// the argument list here and nowhere else.
    private func makeAlert(
        for request: SystemAlarmRequest,
        countdown: Bool
    ) -> AlarmPresentation.Alert {

        let stopButton = AlarmButton(
            text: "Stop",
            textColor: .white,
            systemImageName: "stop.circle"
        )

        if countdown {
            // No mission: AlarmKit's own countdown is the snooze.
            return AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: request.title),
                stopButton: stopButton,
                secondaryButton: AlarmButton(
                    text: "Snooze",
                    textColor: .white,
                    systemImageName: "zzz"
                ),
                secondaryButtonBehavior: .countdown
            )
        }

        // With a mission, the prominent action opens the app and starts it.
        return AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: request.title),
            stopButton: stopButton,
            secondaryButton: AlarmButton(
                text: "Wake up",
                textColor: .white,
                systemImageName: "sun.max.fill"
            ),
            secondaryButtonBehavior: .custom
        )
    }

    private func alertSound(for soundID: String) -> ActivityKit.AlertConfiguration.AlertSound {
        let sound = SoundLibrary.sound(for: soundID)
        // The repo ships without binary audio assets, so fall back rather than
        // scheduling an alarm that references a file the bundle does not have.
        let stem = (sound.fileName as NSString).deletingPathExtension
        let ext = (sound.fileName as NSString).pathExtension
        guard Bundle.main.url(forResource: stem, withExtension: ext) != nil else {
            return .default
        }
        return .named(sound.fileName)
    }
}

// MARK: - Intents

/// Runs when the user taps **Stop** on the system alert.
///
/// It deliberately does *not* resolve the alarm. It records the dismissal
/// honestly and leaves the pre-scheduled Mission Guard chain in place, which is
/// the entire reason the app can promise you cannot silence it in your sleep.
struct StopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Alarm"
    static var description = IntentDescription("Silences the alarm tone.")
    /// No UI: the whole point is that this is not a completion.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Occurrence")
    var occurrenceKey: String

    init() {}

    init(occurrenceKey: String) {
        self.occurrenceKey = occurrenceKey
    }

    func perform() async throws -> some IntentResult {
        await AlarmCoordinator.shared.handleStopPressed(occurrenceKey: occurrenceKey)
        return .result()
    }
}

/// Runs when the user taps the secondary button. Opens the app directly into
/// the mission, so waking up is one tap away and dismissing is not.
struct StartMissionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Mission"
    static var description = IntentDescription("Opens Alarmy and starts your wake-up mission.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Occurrence")
    var occurrenceKey: String

    init() {}

    init(occurrenceKey: String) {
        self.occurrenceKey = occurrenceKey
    }

    func perform() async throws -> some IntentResult {
        await AlarmCoordinator.shared.handleStartMission(occurrenceKey: occurrenceKey)
        return .result()
    }
}
