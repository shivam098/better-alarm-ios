import Foundation
import AlarmyCore

/// Persists which challenges the user has already seen, so the app can promise
/// it will never show the same problem twice within 30 days (PRD M-01 … M-04).
///
/// Small enough for `UserDefaults`: a few thousand short signature strings.
@MainActor
final class ChallengeHistoryStore: ObservableObject {

    private static let key = "com.alarmy.challenge-history"

    @Published private(set) var history: RecentChallengeHistory

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: AlarmStore.appGroupID) ?? .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: ChallengeHistoryStore.key),
           let decoded = try? JSONDecoder().decode(RecentChallengeHistory.self, from: data) {
            self.history = decoded
        } else {
            self.history = RecentChallengeHistory()
        }
    }

    var activeSignatures: Set<String> {
        history.activeSignatures(now: Date())
    }

    func record(_ signature: String) {
        history.record(signature, now: Date())
        persist()
    }

    func reset() {
        history = RecentChallengeHistory()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: ChallengeHistoryStore.key)
    }
}
