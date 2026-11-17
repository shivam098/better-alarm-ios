import Foundation

/// Lifecycle of a single alarm firing (PRD §7.6.1).
public enum AlarmState: String, Codable, Hashable, Sendable {
    case scheduled
    case armed
    case ringing
    case missionActive
    case snoozed
    case completed
    case dismissedUnverified
    case missed

    /// A state from which this firing will not resume on its own.
    public var isTerminal: Bool {
        switch self {
        case .completed, .dismissedUnverified, .missed: return true
        case .scheduled, .armed, .ringing, .missionActive, .snoozed: return false
        }
    }

    /// The alarm is currently demanding the user's attention.
    public var isActive: Bool {
        self == .ringing || self == .missionActive
    }
}

public enum AlarmEvent: Hashable, Sendable {
    case arm
    case fire
    case startMission
    case missionFailed(reason: String)
    case missionCompleted
    case snoozeRequested
    /// The system Stop button, which the app cannot remove from the AlarmKit alert.
    case stopPressed
    case ringTimeout
    case appBackgrounded
    case appForegrounded
    case callStarted
    case callEnded
    case audioRouteChanged
}

public enum AlarmEffect: Hashable, Sendable {
    case startAudio
    case stopAudio
    /// Bring the alarm back to full prominence, e.g. when a call ends (PRD INT-3).
    case rePresentAlarm
    /// Only a genuine completion may do this (PRD MEN-5).
    case cancelWatchdogChain
    /// Explicitly leave the chain armed so the alarm returns.
    case preserveWatchdogChain
    /// Re-anchor the chain to the snooze time so the user is not double-alarmed.
    case rescheduleWatchdogChain
    case recordOutcome(AlarmOutcome)
    case recordFailedAttempt(reason: String)
    /// Never re-show the same problem after a failure (PRD M-01/M-02/M-03).
    case regenerateChallenge
    case scheduleSnooze(minutes: Int)
    case markAudioSuppressed(AudioSuppressionReason)
    case rerouteAudioToSpeaker
    /// Steps/reps already earned must survive backgrounding (PRD MEN-4).
    case preserveMissionProgress
    /// Tell the user why nothing happened, rather than ignoring the tap.
    case notify(String)
}

public struct AlarmTransition: Hashable, Sendable {
    public let state: AlarmState
    public let effects: [AlarmEffect]

    public init(state: AlarmState, effects: [AlarmEffect]) {
        self.state = state
        self.effects = effects
    }
}

/// Everything the reducer needs beyond the current state.
public struct AlarmStateContext: Hashable, Sendable {
    public var snooze: SnoozeSettings
    public var snoozeCount: Int
    public var missionType: MissionType
    /// Whether the mission has already been satisfied during this firing,
    /// which "snooze costs a mission" depends on (PRD SNZ-6).
    public var missionSatisfied: Bool
    public var snoozeAfterMission: Bool

    public init(
        snooze: SnoozeSettings = .default,
        snoozeCount: Int = 0,
        missionType: MissionType = .math,
        missionSatisfied: Bool = false,
        snoozeAfterMission: Bool = false
    ) {
        self.snooze = snooze
        self.snoozeCount = snoozeCount
        self.missionType = missionType
        self.missionSatisfied = missionSatisfied
        self.snoozeAfterMission = snoozeAfterMission
    }
}

/// Pure reducer for the alarm lifecycle.
///
/// The invariants this type exists to guarantee:
///
/// 1. Opening the app is never a completion (PRD MEN-2) — there is no event
///    that transitions to `.completed` other than `.missionCompleted`.
/// 2. A failed attempt never dismisses the alarm (PRD MSN-INT-5).
/// 3. Pressing the system Stop button without a mission yields
///    `.dismissedUnverified`, *not* `.completed`, and leaves the watchdog chain
///    armed (PRD §6.2).
/// 4. Backgrounding, locking or navigating away does not resolve the alarm
///    (PRD MEN-4).
/// 5. A phone call never turns a ringing alarm into a missed one (PRD INT-4).
public enum AlarmStateMachine {

    public static func reduce(
        state: AlarmState,
        event: AlarmEvent,
        context: AlarmStateContext
    ) -> AlarmTransition {

        switch (state, event) {

        // MARK: Arming and firing

        case (.scheduled, .arm):
            return AlarmTransition(state: .armed, effects: [])

        case (.scheduled, .fire), (.armed, .fire), (.snoozed, .fire):
            return AlarmTransition(state: .ringing, effects: [.startAudio])

        // MARK: Mission

        case (.ringing, .startMission):
            return AlarmTransition(state: .missionActive, effects: [])

        case (.missionActive, .missionFailed(let reason)):
            // Invariant 2: a wrong answer costs the user a new problem, never the alarm.
            return AlarmTransition(
                state: .missionActive,
                effects: [.recordFailedAttempt(reason: reason), .regenerateChallenge]
            )

        case (.ringing, .missionCompleted), (.missionActive, .missionCompleted):
            if context.snoozeAfterMission {
                var satisfied = context
                satisfied.missionSatisfied = true
                satisfied.snoozeAfterMission = false
                return reduce(state: state, event: .snoozeRequested, context: satisfied)
            }
            return AlarmTransition(
                state: .completed,
                effects: [.stopAudio, .cancelWatchdogChain, .recordOutcome(.completed)]
            )

        // MARK: The system Stop button

        case (.ringing, .stopPressed), (.missionActive, .stopPressed):
            if context.missionType == .none {
                // With no mission configured, Stop *is* the configured dismissal.
                return AlarmTransition(
                    state: .completed,
                    effects: [.stopAudio, .cancelWatchdogChain, .recordOutcome(.completed)]
                )
            }
            // Invariant 3: silence the tone, but the alarm is not resolved.
            return AlarmTransition(
                state: .dismissedUnverified,
                effects: [
                    .stopAudio,
                    .preserveWatchdogChain,
                    .recordOutcome(.dismissedUnverified)
                ]
            )

        // MARK: Snooze

        case (.ringing, .snoozeRequested), (.missionActive, .snoozeRequested):
            guard context.snooze.isEnabled else {
                return AlarmTransition(state: state, effects: [.notify("Snooze is turned off for this alarm.")])
            }
            if let limit = context.snooze.limit, context.snoozeCount >= limit {
                // PRD SNZ-7: once the limit is reached the mission is the only way out.
                return AlarmTransition(
                    state: state,
                    effects: [.notify("No snoozes left — finish the mission to turn this off.")]
                )
            }
            if context.snooze.costsMission && !context.missionSatisfied {
                return AlarmTransition(
                    state: state,
                    effects: [.notify("Complete the mission first, then you can snooze.")]
                )
            }
            let minutes = SnoozePolicy.duration(for: context.snooze, snoozeCount: context.snoozeCount)
            // PRD SNZ-4: snoozing is recorded as a snooze, never as a completion.
            return AlarmTransition(
                state: .snoozed,
                effects: [
                    .scheduleSnooze(minutes: minutes),
                    .stopAudio,
                    .rescheduleWatchdogChain,
                    .recordOutcome(.snoozed)
                ]
            )

        // MARK: Timeout

        case (.ringing, .ringTimeout), (.missionActive, .ringTimeout):
            // The firing is over, but Mission Guard keeps the alarm coming back.
            return AlarmTransition(
                state: .missed,
                effects: [.stopAudio, .preserveWatchdogChain, .recordOutcome(.missed)]
            )

        // MARK: App lifecycle — invariant 4

        case (.missionActive, .appBackgrounded), (.missionActive, .appForegrounded):
            return AlarmTransition(state: .missionActive, effects: [.preserveMissionProgress])

        case (.ringing, .appBackgrounded), (.ringing, .appForegrounded):
            return AlarmTransition(state: .ringing, effects: [])

        // MARK: Calls — invariant 5

        case (.ringing, .callStarted), (.missionActive, .callStarted):
            // The system owns call audio. We keep the alarm alive and record why
            // it may have been inaudible; we never pretend it was missed.
            return AlarmTransition(state: state, effects: [.markAudioSuppressed(.phoneCall)])

        case (.ringing, .callEnded), (.missionActive, .callEnded):
            return AlarmTransition(state: state, effects: [.rePresentAlarm, .startAudio])

        // MARK: Audio routing

        case (.ringing, .audioRouteChanged), (.missionActive, .audioRouteChanged):
            // Never let the alarm end up audible only in a disconnected accessory.
            return AlarmTransition(state: state, effects: [.rerouteAudioToSpeaker])

        // MARK: Everything else is a no-op

        default:
            return AlarmTransition(state: state, effects: [])
        }
    }
}

/// Snooze rules (PRD SNZ-1 … SNZ-8).
public enum SnoozePolicy {

    /// Round is encoded in system keys as well as history so relaunching cannot
    /// reset a limit, even if the user has cleared history.
    public static func count(in occurrenceKey: String) -> Int {
        max(0, occurrenceKey.split(separator: "#").compactMap { component in
            guard component.hasPrefix("snooze") else { return nil }
            return Int(component.dropFirst("snooze".count))
        }.max() ?? 0)
    }

    public static func canSnooze(
        settings: SnoozeSettings,
        snoozeCount: Int,
        missionSatisfied: Bool
    ) -> Bool {
        guard settings.isEnabled else { return false }
        if let limit = settings.limit, snoozeCount >= limit { return false }
        if settings.costsMission && !missionSatisfied { return false }
        return true
    }

    /// Successive snoozes get shorter when escalation is on: 9 → 5 → 3 minutes.
    public static func duration(for settings: SnoozeSettings, snoozeCount: Int) -> Int {
        guard settings.escalating else { return settings.duration }
        let base = settings.duration
        let ladder = [base, max(1, base * 5 / 9), max(1, base * 3 / 9)]
        return ladder[min(max(0, snoozeCount), ladder.count - 1)]
    }

    public static func remaining(settings: SnoozeSettings, snoozeCount: Int) -> Int? {
        guard let limit = settings.limit else { return nil }
        return max(0, limit - snoozeCount)
    }
}
