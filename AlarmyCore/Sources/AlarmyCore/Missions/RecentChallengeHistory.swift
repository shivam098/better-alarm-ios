import Foundation

/// Remembers which challenges a user has already been shown, so the same problem
/// is not served twice within the retention window.
///
/// This is what makes "the app should generate different problems rather than
/// showing the exact same problem every time" enforceable rather than aspirational
/// (PRD M-01, M-02, M-03, M-04).
public struct RecentChallengeHistory: Codable, Hashable, Sendable {
    public private(set) var entries: [String: Date]
    public var retention: TimeInterval

    /// 30 days.
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60
    /// Beyond this, evicting the oldest is preferable to unbounded growth.
    public static let maxEntries = 2000

    public init(entries: [String: Date] = [:], retention: TimeInterval = RecentChallengeHistory.defaultRetention) {
        self.entries = entries
        self.retention = retention
    }

    public func contains(_ signature: String, now: Date) -> Bool {
        guard let seen = entries[signature] else { return false }
        return now.timeIntervalSince(seen) < retention
    }

    public mutating func record(_ signature: String, now: Date) {
        entries[signature] = now
        prune(now: now)
    }

    public mutating func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value) < retention }

        if entries.count > Self.maxEntries {
            let survivors = entries
                .sorted { $0.value > $1.value }
                .prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        }
    }

    /// Signatures seen within the window.
    public func activeSignatures(now: Date) -> Set<String> {
        Set(entries.filter { now.timeIntervalSince($0.value) < retention }.keys)
    }
}

/// Generates a value that has not been seen recently.
///
/// Falls back to the last candidate after `maxAttempts` so a user with a long
/// history can never be locked out of their own alarm.
public enum UniqueChallengeFactory {
    public static func make<T>(
        excluding history: Set<String>,
        maxAttempts: Int = 24,
        signature: (T) -> String,
        produce: () -> T
    ) -> T {
        var candidate = produce()
        var attempts = 0
        while history.contains(signature(candidate)) && attempts < maxAttempts {
            candidate = produce()
            attempts += 1
        }
        return candidate
    }
}
