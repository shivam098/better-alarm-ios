import Foundation
import Combine
import AlarmyCore

/// A firing that is happening right now.
struct RingingSession: Identifiable, Equatable {
    let id: UUID
    let occurrenceKey: String
    let alarm: Alarm
    var mission: MissionConfig
    var state: AlarmState
    var snoozeCount: Int
    var missionSatisfied: Bool
    var startedAt: Date
    var substitutedFrom: MissionType?
    var lastMessage: String?

    var rootKey: String { AlarmStore.rootKey(of: occurrenceKey) }

    var context: AlarmStateContext {
        AlarmStateContext(
            snooze: alarm.snooze,
            snoozeCount: snoozeCount,
            missionType: mission.type,
            missionSatisfied: missionSatisfied
        )
    }
}

/// The single place where alarm logic, the operating system and the UI meet.
///
/// It owns no rules of its own: every decision is delegated to `AlarmyCore`'s
/// pure reducer, and this type only performs the resulting effects. That keeps
/// the interesting behaviour unit-testable without a device.
@MainActor
final class AlarmCoordinator: ObservableObject {

    static let shared = AlarmCoordinator()

    @Published private(set) var alarms: [Alarm] = []
    @Published private(set) var occurrences: [AlarmOccurrence] = []
    @Published private(set) var authorization: SystemAlarmAuthorization = .notDetermined
    @Published private(set) var deniedPermissions: Set<MissionPermission> = []
    /// Non-nil when an alarm is ringing or its mission is in progress.
    @Published var session: RingingSession?
    /// Set when something the user should know about happened (PRD UX-6).
    @Published var banner: String?

    private let store: AlarmStore
    private let scheduler: any SystemAlarmScheduling
    private let builder: AlarmRequestBuilder
    private let permissions: PermissionManager
    private var eventTask: Task<Void, Never>?

    /// Conservative cap on simultaneously-pending system alarms. AlarmKit does
    /// not document a limit, so the app stays well inside any plausible one and
    /// prioritises rather than assuming (PRD REL-3, open question Q2).
    private let schedulingCapacity = 48

    init(
        store: AlarmStore = AlarmStore(),
        scheduler: (any SystemAlarmScheduling)? = nil,
        permissions: PermissionManager = PermissionManager(),
        calendar: Calendar = .current
    ) {
        self.store = store
        self.scheduler = scheduler ?? AlarmKitScheduler()
        self.builder = AlarmRequestBuilder(calendar: calendar)
        self.permissions = permissions
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        authorization = await scheduler.authorizationStatus()
        deniedPermissions = await permissions.deniedPermissions()
        await reload()
        await reconcile()
        observeSystemEvents()
    }

    func requestAlarmAuthorization() async {
        authorization = await scheduler.requestAuthorization()
        if authorization == .authorized {
            await reconcile()
        }
    }

    private func reload() async {
        alarms = await store.allAlarms()
        occurrences = await store.allOccurrences()
    }

    private func observeSystemEvents() {
        eventTask?.cancel()
        let stream = scheduler.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .alerting(let id):
                    await self.handleAlerting(systemID: id)
                case .ended:
                    break
                }
            }
        }
    }

    // MARK: - Alarm CRUD

    func save(_ alarm: Alarm) async {
        await store.upsert(alarm)
        await reload()
        await reconcile()
    }

    func delete(_ alarm: Alarm) async {
        await store.delete(id: alarm.id)
        await reload()
        await reconcile()
    }

    func setEnabled(_ isEnabled: Bool, for alarm: Alarm) async {
        var updated = alarm
        updated.isEnabled = isEnabled
        await save(updated)
    }

    func clearHistory() async {
        await store.deleteAllHistory()
        await reload()
    }

    // MARK: - Reconciliation

    /// Rebuilds the entire set of system alarms from the stored alarms.
    ///
    /// Run at launch, after every edit and after every firing. Because every
    /// system alarm's identifier is derived deterministically from its
    /// occurrence key, re-running this is idempotent: it can never produce a
    /// duplicate alarm, no matter how many reboots, time-zone changes or sync
    /// merges preceded it (PRD TIM-5, REL-6).
    func reconcile(now: Date = Date()) async {
        guard authorization == .authorized else { return }

        let wishlist = alarms.flatMap { builder.requests(for: $0, from: now) }
        let affordable = builder.withinBudget(wishlist, now: now, capacity: schedulingCapacity)

        // Preserve any live guard chain: it belongs to a firing already in
        // flight and is not represented in the wish-list.
        var liveChainKeys: Set<String> = []
        if let session {
            liveChainKeys = Set(await store.keysInChain(parentKey: session.rootKey))
        }

        let desiredKeys = Set(affordable.map(\.occurrenceKey)).union(liveChainKeys)
        let previousKeys = await store.scheduledOccurrenceKeys()

        let staleIDs = previousKeys.subtracting(desiredKeys).map(SystemAlarmRequest.identifier(for:))
        await scheduler.cancel(ids: staleIDs)

        do {
            try await scheduler.schedule(affordable)
            await store.setScheduledKeys(desiredKeys)
            if wishlist.count > affordable.count {
                AlarmyLog.scheduling.notice(
                    "Scheduling budget trimmed \(wishlist.count - affordable.count) alarms"
                )
            }
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? "Some alarms couldn't be scheduled."
            AlarmyLog.scheduling.error("Reconcile failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Firing

    private func handleAlerting(systemID: UUID) async {
        let keys = await store.scheduledOccurrenceKeys()
        guard let key = keys.first(where: { SystemAlarmRequest.identifier(for: $0) == systemID }) else {
            return
        }
        await beginSession(occurrenceKey: key)
    }

    /// Called by `StartMissionIntent` when the user taps the secondary button.
    func handleStartMission(occurrenceKey: String) async {
        await beginSession(occurrenceKey: occurrenceKey)
        guard var current = session else { return }
        let transition = AlarmStateMachine.reduce(
            state: current.state, event: .startMission, context: current.context
        )
        current.state = transition.state
        session = current
        await apply(transition.effects, for: current)
    }

    /// Called by `StopAlarmIntent`. This is the moment the product's core
    /// promise is kept: the tone stops, the outcome is recorded honestly as
    /// `dismissedUnverified`, and the Mission Guard chain stays armed.
    func handleStopPressed(occurrenceKey: String) async {
        await beginSession(occurrenceKey: occurrenceKey)
        guard var current = session else { return }

        let transition = AlarmStateMachine.reduce(
            state: current.state, event: .stopPressed, context: current.context
        )
        current.state = transition.state
        session = current
        await apply(transition.effects, for: current)

        if transition.state.isTerminal { session = nil }
        await reload()
    }

    func completeMission() async {
        guard var current = session else { return }
        current.missionSatisfied = true

        let transition = AlarmStateMachine.reduce(
            state: current.state, event: .missionCompleted, context: current.context
        )
        current.state = transition.state
        session = current
        await apply(transition.effects, for: current)

        session = nil
        await reload()
        await reconcile()
    }

    func failMission(reason: MissionFailure) async {
        guard var current = session else { return }
        let transition = AlarmStateMachine.reduce(
            state: current.state,
            event: .missionFailed(reason: String(describing: reason)),
            context: current.context
        )
        current.state = transition.state
        current.lastMessage = reason.userMessage
        session = current
        await apply(transition.effects, for: current)
    }

    func requestSnooze() async {
        guard var current = session else { return }
        let transition = AlarmStateMachine.reduce(
            state: current.state, event: .snoozeRequested, context: current.context
        )

        if transition.state == .snoozed {
            current.snoozeCount += 1
        }
        current.state = transition.state
        session = current
        await apply(transition.effects, for: current)

        if transition.state == .snoozed {
            session = nil
            await reload()
        }
    }

    func noteAppLifecycle(_ event: AlarmEvent) async {
        guard var current = session else { return }
        let transition = AlarmStateMachine.reduce(
            state: current.state, event: event, context: current.context
        )
        current.state = transition.state
        session = current
        await apply(transition.effects, for: current)
    }

    // MARK: - Session construction

    private func beginSession(occurrenceKey: String) async {
        if session?.occurrenceKey == occurrenceKey { return }

        let rootKey = AlarmStore.rootKey(of: occurrenceKey)
        guard let alarm = alarms.first(where: { rootKey.hasPrefix($0.id.uuidString) })
            ?? (await store.allAlarms()).first(where: { rootKey.hasPrefix($0.id.uuidString) })
        else {
            AlarmyLog.firing.error("Fired with no matching alarm: \(occurrenceKey, privacy: .public)")
            return
        }

        // Escalate if this is a watchdog, and substitute the mission if a
        // permission it needs has since been revoked (PRD PRM-5).
        var mission = alarm.mission
        if occurrenceKey.contains("#wd"), alarm.missionGuard.escalates {
            mission = mission.escalated()
        }

        var substitutedFrom: MissionType?
        deniedPermissions = await permissions.deniedPermissions()
        if !mission.requiredPermissions.isDisjoint(with: deniedPermissions) {
            substitutedFrom = mission.type
            let fallback = alarm.resolvedFallback(excluding: deniedPermissions)
            mission = MissionConfig(type: fallback, difficulty: mission.difficulty)
            banner = "\(substitutedFrom!.displayName) needs a permission you've turned off, so we switched to \(fallback.displayName)."
        }

        let scheduledAt = Date()
        let occurrence = AlarmOccurrence(
            alarmID: alarm.id,
            occurrenceKey: occurrenceKey,
            scheduledAt: scheduledAt,
            firedAt: scheduledAt,
            missionType: mission.type,
            difficulty: mission.difficulty,
            substitutedFrom: substitutedFrom
        )
        // Written before the UI updates, so a crash cannot lose the record.
        await store.record(occurrence)

        session = RingingSession(
            id: SystemAlarmRequest.identifier(for: occurrenceKey),
            occurrenceKey: occurrenceKey,
            alarm: alarm,
            mission: mission,
            state: .ringing,
            snoozeCount: 0,
            missionSatisfied: false,
            startedAt: scheduledAt,
            substitutedFrom: substitutedFrom
        )
        await reload()
    }

    // MARK: - Effects

    private func apply(_ effects: [AlarmEffect], for session: RingingSession) async {
        for effect in effects {
            switch effect {

            case .cancelWatchdogChain:
                // Only ever reached from `.missionCompleted`.
                let keys = await store.keysInChain(parentKey: session.rootKey)
                await scheduler.cancel(ids: keys.map(SystemAlarmRequest.identifier(for:)))
                var remaining = await store.scheduledOccurrenceKeys()
                remaining.subtract(keys)
                await store.setScheduledKeys(remaining)
                AlarmyLog.firing.notice("Mission completed — guard chain cancelled")

            case .preserveWatchdogChain:
                // Deliberately nothing. The chain is what brings the alarm back.
                AlarmyLog.firing.notice("Alarm silenced without a mission — guard chain left armed")

            case .rescheduleWatchdogChain:
                break // Handled as part of `.scheduleSnooze`.

            case .scheduleSnooze(let minutes):
                await scheduleSnooze(minutes: minutes, for: session)

            case .recordOutcome(let outcome):
                let elapsed = Int(Date().timeIntervalSince(session.startedAt) * 1000)
                await store.updateOccurrence(key: session.occurrenceKey) { occurrence in
                    occurrence.outcome = outcome
                    occurrence.resolvedAt = Date()
                    occurrence.snoozeCount = session.snoozeCount
                    if outcome == .completed { occurrence.timeToCompleteMS = elapsed }
                }

            case .recordFailedAttempt(let reason):
                await store.updateOccurrence(key: session.occurrenceKey) { occurrence in
                    occurrence.attempts += 1
                    occurrence.failureReasons.append(reason)
                }

            case .stopAudio:
                await scheduler.stopRinging(id: session.id)

            case .markAudioSuppressed(let reason):
                await store.updateOccurrence(key: session.occurrenceKey) { occurrence in
                    occurrence.audioSuppression = reason
                }
                if let explanation = reason.userExplanation { banner = explanation }

            case .notify(let message):
                banner = message

            case .startAudio, .rePresentAlarm, .regenerateChallenge,
                 .preserveMissionProgress, .rerouteAudioToSpeaker:
                // Handled by the mission runner and the audio session, which own
                // that state directly.
                break
            }
        }
    }

    private func scheduleSnooze(minutes: Int, for session: RingingSession) async {
        let fireDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let requests = builder.snoozeRequests(
            for: session.alarm,
            parentKey: session.rootKey,
            round: session.snoozeCount,
            firingAt: fireDate
        )

        do {
            try await scheduler.schedule(requests)
            var keys = await store.scheduledOccurrenceKeys()
            keys.formUnion(requests.map(\.occurrenceKey))
            await store.setScheduledKeys(keys)
            banner = "Snoozed for \(minutes) minutes."
        } catch {
            banner = "Snooze failed — the alarm will ring again shortly."
            AlarmyLog.scheduling.error("Snooze scheduling failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Derived state

    var statistics: WakeStatistics {
        StatisticsCalculator.summarise(occurrences)
    }

    /// Everything currently standing between the user and a reliable alarm
    /// (PRD REL-9, the Reliability Check screen).
    var reliabilityIssues: [ReliabilityIssue] {
        var issues: [ReliabilityIssue] = []

        switch authorization {
        case .notDetermined:
            issues.append(.alarmPermissionMissing)
        case .denied:
            issues.append(.alarmPermissionDenied)
        case .unavailable:
            issues.append(.platformTooOld)
        case .authorized:
            break
        }

        let needed = Set(alarms.filter(\.isEnabled).flatMap { $0.mission.requiredPermissions })
        for permission in needed.intersection(deniedPermissions).sorted(by: { $0.rawValue < $1.rawValue }) {
            issues.append(.missionPermissionDenied(permission))
        }

        if alarms.contains(where: { $0.isEnabled && !$0.isGuarded && $0.mission.type != .none }) {
            issues.append(.missionGuardOff)
        }

        return issues
    }
}

enum ReliabilityIssue: Hashable, Identifiable {
    case alarmPermissionMissing
    case alarmPermissionDenied
    case platformTooOld
    case missionPermissionDenied(MissionPermission)
    case missionGuardOff

    var id: String { String(describing: self) }

    var title: String {
        switch self {
        case .alarmPermissionMissing: return "Alarm permission not granted yet"
        case .alarmPermissionDenied: return "Alarm permission is turned off"
        case .platformTooOld: return "This iOS version can't run reliable alarms"
        case .missionPermissionDenied(let permission): return "\(permission.displayName) access is off"
        case .missionGuardOff: return "Mission Guard is off for some alarms"
        }
    }

    /// Plain language, no blame, and always a next step (PRD UX-6).
    var detail: String {
        switch self {
        case .alarmPermissionMissing:
            return "Alarmy needs permission to schedule alarms that break through Silent Mode and Focus."
        case .alarmPermissionDenied:
            return "Without this, your alarms will not sound when your phone is silenced. Turn it back on in Settings."
        case .platformTooOld:
            return "Reliable alarms need iOS 26 or later. Alarms will still work, but they will respect the mute switch."
        case .missionPermissionDenied(let permission):
            return "Alarms using this mission will switch to a backup mission. \(permission.rationale)"
        case .missionGuardOff:
            return "Pressing Stop on these alarms will silence them for good, even if you never got up."
        }
    }

    var isBlocking: Bool {
        switch self {
        case .alarmPermissionMissing, .alarmPermissionDenied, .platformTooOld: return true
        case .missionPermissionDenied, .missionGuardOff: return false
        }
    }
}
