import Foundation
import AlarmyCore

/// Durable storage for alarms, occurrences and the set of occurrence keys we
/// have handed to the system.
///
/// Design notes:
///
/// * Plain JSON in the **App Group** container, not `UserDefaults` and not a
///   database. The widget and the App Intents need to read the same state, and
///   an alarm app must survive a crash mid-write — so every write is atomic
///   (write to a temporary file, then replace).
/// * Occurrence rows are written *before* the UI updates (PRD REL-11), so a
///   crash during a firing cannot lose the record of what happened.
actor AlarmStore {

    static let appGroupID = "group.com.alarmy.app"

    private let directory: URL
    private let alarmsURL: URL
    private let occurrencesURL: URL
    private let scheduledKeysURL: URL
    private let wakeChecksURL: URL
    private let snoozesURL: URL

    private var alarms: [Alarm] = []
    private var occurrences: [AlarmOccurrence] = []
    private var scheduledKeys: Set<String> = []
    private var wakeChecks: [PendingWakeCheck] = []
    private var snoozes: [PendingSnooze] = []
    private var loaded = false

    /// Keeps history bounded so the file stays small on a device that has been
    /// waking someone up daily for years (PRD HIS-5).
    private let historyLimit = 2000

    init(directory: URL? = nil) {
        let resolved = directory
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AlarmStore.appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        self.directory = resolved
        self.alarmsURL = resolved.appendingPathComponent("alarms.json")
        self.occurrencesURL = resolved.appendingPathComponent("occurrences.json")
        self.scheduledKeysURL = resolved.appendingPathComponent("scheduled-keys.json")
        self.wakeChecksURL = resolved.appendingPathComponent("wake-checks.json")
        self.snoozesURL = resolved.appendingPathComponent("snoozes.json")
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        alarms = decode([Alarm].self, from: alarmsURL) ?? []
        occurrences = decode([AlarmOccurrence].self, from: occurrencesURL) ?? []
        scheduledKeys = Set(decode([String].self, from: scheduledKeysURL) ?? [])
        wakeChecks = decode([PendingWakeCheck].self, from: wakeChecksURL) ?? []
        snoozes = decode([PendingSnooze].self, from: snoozesURL) ?? []
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            // A corrupt file must not brick the app. Losing settings is bad;
            // an alarm app that will not launch is worse.
            AlarmyLog.persistence.error("Corrupt store at \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(value) else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            AlarmyLog.persistence.error("Write failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Alarms

    func allAlarms() -> [Alarm] {
        loadIfNeeded()
        return alarms.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    func alarm(id: UUID) -> Alarm? {
        loadIfNeeded()
        return alarms.first { $0.id == id }
    }

    func upsert(_ alarm: Alarm) {
        loadIfNeeded()
        var updated = alarm
        updated.mission = alarm.mission.normalized()
        updated.updatedAt = Date()

        if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[index] = updated
        } else {
            alarms.append(updated)
        }
        write(alarms, to: alarmsURL)
    }

    func delete(id: UUID) {
        loadIfNeeded()
        alarms.removeAll { $0.id == id }
        write(alarms, to: alarmsURL)
    }

    // MARK: - Occurrences

    func allOccurrences() -> [AlarmOccurrence] {
        loadIfNeeded()
        return occurrences.sorted { $0.scheduledAt > $1.scheduledAt }
    }

    func occurrence(key: String) -> AlarmOccurrence? {
        loadIfNeeded()
        return occurrences.first { $0.occurrenceKey == key }
    }

    /// Inserts or updates by `occurrenceKey`. This is the idempotency point:
    /// reconciliation, reboots and sync merges all funnel through here, so the
    /// same firing can never appear twice (PRD TIM-5).
    @discardableResult
    func record(_ occurrence: AlarmOccurrence) -> AlarmOccurrence {
        loadIfNeeded()

        if let index = occurrences.firstIndex(where: { $0.occurrenceKey == occurrence.occurrenceKey }) {
            var merged = occurrence
            merged.id = occurrences[index].id
            occurrences[index] = merged
            write(occurrences, to: occurrencesURL)
            return merged
        }

        occurrences.append(occurrence)
        if occurrences.count > historyLimit {
            occurrences.sort { $0.scheduledAt > $1.scheduledAt }
            occurrences = Array(occurrences.prefix(historyLimit))
        }
        write(occurrences, to: occurrencesURL)
        return occurrence
    }

    func updateOccurrence(key: String, _ mutate: (inout AlarmOccurrence) -> Void) {
        loadIfNeeded()
        guard let index = occurrences.firstIndex(where: { $0.occurrenceKey == key }) else { return }
        mutate(&occurrences[index])
        write(occurrences, to: occurrencesURL)
    }

    func deleteAllHistory() {
        loadIfNeeded()
        occurrences.removeAll()
        write(occurrences, to: occurrencesURL)
    }

    // MARK: - Scheduled keys

    func scheduledOccurrenceKeys() -> Set<String> {
        loadIfNeeded()
        return scheduledKeys
    }

    func setScheduledKeys(_ keys: Set<String>) {
        loadIfNeeded()
        scheduledKeys = keys
        write(Array(keys).sorted(), to: scheduledKeysURL)
    }

    func allWakeChecks() -> [PendingWakeCheck] {
        loadIfNeeded()
        return wakeChecks
    }

    func setWakeChecks(_ checks: [PendingWakeCheck]) throws {
        loadIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(checks).write(to: wakeChecksURL, options: .atomic)
        wakeChecks = checks
    }

    func allSnoozes() -> [PendingSnooze] {
        loadIfNeeded()
        return snoozes
    }

    func setSnoozes(_ pending: [PendingSnooze]) throws {
        loadIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(pending).write(to: snoozesURL, options: .atomic)
        snoozes = pending
    }

    /// Every key belonging to the same firing: the parent plus its watchdogs and
    /// snoozes. Used to cancel a Mission Guard chain atomically.
    func keysInChain(parentKey: String) -> [String] {
        loadIfNeeded()
        let root = AlarmStore.rootKey(of: parentKey)
        return scheduledKeys.filter { AlarmStore.rootKey(of: $0) == root }.sorted()
    }

    /// Watchdog and snooze keys are `parent#wd3` / `parent#snooze1`, so the root
    /// is everything before the first `#`.
    nonisolated static func rootKey(of key: String) -> String {
        guard let hash = key.firstIndex(of: "#") else { return key }
        return String(key[key.startIndex..<hash])
    }
}
