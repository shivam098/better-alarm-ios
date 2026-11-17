import XCTest
import AlarmyCore
@testable import Alarmy

@MainActor
final class AlarmCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ alarm: Alarm) async -> (AlarmCoordinator, AlarmStore, TestScheduler, String) {
        let store = AlarmStore(directory: directory)
        await store.upsert(alarm)
        let scheduler = TestScheduler()
        let coordinator = AlarmCoordinator(store: store, scheduler: scheduler)
        await coordinator.bootstrap()
        let key = OccurrenceKey.make(alarmID: alarm.id, fireDate: Date(), calendar: .current)
        return (coordinator, store, scheduler, key)
    }

    func testSnoozeCountAndShorteningSurviveRelaunchAndHistoryClear() async throws {
        let alarm = Alarm(snooze: SnoozeSettings(duration: 9, limit: 2, escalating: true),
                          missionGuard: MissionGuardSettings(isEnabled: false))
        let (first, store, scheduler, key) = await fixture(alarm)
        await first.handleStartMission(occurrenceKey: key)
        await first.requestSnooze()
        XCTAssertNil(first.session)
        await store.deleteAllHistory()

        let restoredStore = AlarmStore(directory: directory)
        let restored = AlarmCoordinator(store: restoredStore, scheduler: scheduler)
        await restored.bootstrap()
        await restored.handleStartMission(occurrenceKey: "\(key)#snooze1")
        XCTAssertEqual(restored.session?.snoozeCount, 1)
        let before = Date()
        await restored.requestSnooze()
        let pending = await restoredStore.allSnoozes()
        XCTAssertEqual(pending.first?.round, 2)
        XCTAssertEqual(try XCTUnwrap(pending.first).fireDate.timeIntervalSince(before), 300, accuracy: 3)
        await restored.handleStartMission(occurrenceKey: "\(key)#snooze2")
        await restored.requestSnooze()
        XCTAssertEqual(restored.session?.snoozeCount, 2)
        XCTAssertNotNil(restored.session)
    }

    func testMissionBeforeSnoozeDoesNotCompleteAlarmOrLoseGuard() async {
        let alarm = Alarm(snooze: SnoozeSettings(costsMission: true))
        let (coordinator, store, scheduler, key) = await fixture(alarm)
        await coordinator.handleStartMission(occurrenceKey: key)
        await coordinator.requestSnooze()
        XCTAssertEqual(coordinator.session?.snoozeAfterMission, true)
        XCTAssertNotNil(coordinator.session)
        await coordinator.completeMission()
        XCTAssertNil(coordinator.session)
        let outcome = await store.occurrence(key: key)
        XCTAssertEqual(outcome?.outcome, .snoozed)
        XCTAssertEqual(outcome?.snoozeCount, 1)
        let requests = await scheduler.allRequests()
        XCTAssertTrue(requests.contains { $0.occurrenceKey == "\(key)#snooze1#wd0" || $0.occurrenceKey == "\(key)#snooze1#wd1" })
    }

    func testFailedSnoozeKeepsSessionAndOriginalGuardActive() async {
        let (coordinator, store, scheduler, key) = await fixture(Alarm())
        await coordinator.handleStartMission(occurrenceKey: key)
        let before = await scheduler.allRequests()
        await scheduler.setFailure(true)
        await coordinator.requestSnooze()
        XCTAssertNotNil(coordinator.session)
        XCTAssertEqual(coordinator.session?.snoozeCount, 0)
        let pending = await store.allSnoozes()
        XCTAssertTrue(pending.isEmpty)
        let after = await scheduler.allRequests()
        XCTAssertEqual(Set(before.map(\.id)), Set(after.map(\.id)))
    }

    func testWakeCheckSurvivesHistoryClearAndStopAndCancelsOnlyOnConfirmation() async throws {
        let alarm = Alarm(wakeCheck: WakeCheckSettings(isEnabled: true))
        let (coordinator, store, scheduler, key) = await fixture(alarm)
        await coordinator.handleStartMission(occurrenceKey: key)
        await coordinator.completeMission()
        let checks = await store.allWakeChecks()
        let check = try XCTUnwrap(checks.first)
        let scheduled = await scheduler.allRequests()
        XCTAssertTrue(scheduled.contains { $0.occurrenceKey == check.reAlarmKey })
        await coordinator.clearHistory()
        let restored = AlarmStore(directory: directory)
        let restoredChecks = await restored.allWakeChecks()
        XCTAssertEqual(restoredChecks, checks)
        await coordinator.handleStopPressed(occurrenceKey: check.checkKey)
        let afterStop = await store.allWakeChecks()
        XCTAssertEqual(afterStop, checks)
        await coordinator.handleStartMission(occurrenceKey: check.checkKey)
        XCTAssertNotNil(coordinator.session, "Opening the app is not confirmation")
        await coordinator.completeMission()
        let afterConfirmation = await store.allWakeChecks()
        XCTAssertTrue(afterConfirmation.isEmpty)
        let remaining = await scheduler.allRequests()
        XCTAssertFalse(remaining.contains { $0.occurrenceKey == check.reAlarmKey })
    }

    func testSnoozeWatchdogCannotBeSnoozedAgain() async {
        let (coordinator, _, _, key) = await fixture(Alarm())
        await coordinator.handleStartMission(occurrenceKey: "\(key)#snooze1#wd1")
        await coordinator.requestSnooze()
        XCTAssertEqual(coordinator.session?.snoozeCount, 1)
        XCTAssertNotNil(coordinator.session)
    }

    func testBundledTonesAreAvailableForInAppPlayback() {
        let bundle = Bundle(for: AlarmCoordinator.self)
        for sound in SoundLibrary.all {
            let stem = (sound.fileName as NSString).deletingPathExtension
            XCTAssertNotNil(bundle.url(forResource: stem, withExtension: "wav"), sound.fileName)
        }
    }
}

private actor TestScheduler: SystemAlarmScheduling {
    private var requests: [UUID: SystemAlarmRequest] = [:]
    private var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func allRequests() -> [SystemAlarmRequest] { Array(requests.values) }
    func authorizationStatus() async -> SystemAlarmAuthorization { .authorized }
    func requestAuthorization() async -> SystemAlarmAuthorization { .authorized }
    func schedule(_ values: [SystemAlarmRequest]) async throws {
        if fails { throw SystemAlarmError.schedulingFailed("Test failure") }
        for request in values { requests[request.id] = request }
    }
    func cancel(ids: [UUID]) async { for id in ids { requests[id] = nil } }
    func stopRinging(id: UUID) async {}
    func pendingIdentifiers() async -> Set<UUID> { Set(requests.keys) }
    nonisolated func events() -> AsyncStream<SystemAlarmEvent> { AsyncStream { $0.finish() } }
}
