import Foundation

/// What to do about an alarm whose time passed while the device was off,
/// restarting, or otherwise unavailable (PRD TIM-6 … TIM-8).
public enum MissedWindowRule: String, Codable, Hashable, CaseIterable, Sendable {
    /// Fire immediately if we are still within the grace period; otherwise skip. Default.
    case gracePeriod
    case alwaysSkip
    case alwaysTrigger

    public var displayName: String {
        switch self {
        case .gracePeriod: return "Ring if recent"
        case .alwaysSkip: return "Skip"
        case .alwaysTrigger: return "Always ring"
        }
    }

    public var explanation: String {
        switch self {
        case .gracePeriod:
            return "If your phone was off, the alarm rings as soon as it comes back — but only if it missed by less than the grace period."
        case .alwaysSkip:
            return "A missed alarm is skipped and recorded in your history."
        case .alwaysTrigger:
            return "A missed alarm rings as soon as your phone is available, however late."
        }
    }
}

public enum MissedWindowDecision: Hashable, Sendable {
    /// Ring now. `lateBy` is how far past the scheduled time we are.
    case triggerNow(lateBy: TimeInterval)
    /// Do not ring; record as missed and tell the user (PRD TIM-8).
    case skipAndRecordMissed(lateBy: TimeInterval)
    /// Still in the future; nothing to decide.
    case notYetDue
}

public struct MissedWindowPolicy: Sendable {
    public var rule: MissedWindowRule
    public var graceMinutes: Int

    public init(rule: MissedWindowRule = .gracePeriod, graceMinutes: Int = 15) {
        self.rule = rule
        self.graceMinutes = graceMinutes
    }

    public func decide(scheduledAt: Date, now: Date) -> MissedWindowDecision {
        let lateBy = now.timeIntervalSince(scheduledAt)
        guard lateBy > 0 else { return .notYetDue }

        switch rule {
        case .alwaysTrigger:
            return .triggerNow(lateBy: lateBy)
        case .alwaysSkip:
            return .skipAndRecordMissed(lateBy: lateBy)
        case .gracePeriod:
            return lateBy <= TimeInterval(graceMinutes * 60)
                ? .triggerNow(lateBy: lateBy)
                : .skipAndRecordMissed(lateBy: lateBy)
        }
    }

    /// User-facing sentence explaining what just happened. Never silent (PRD TIM-8).
    public func disclosure(for decision: MissedWindowDecision, alarmName: String) -> String? {
        switch decision {
        case .notYetDue:
            return nil
        case .triggerNow(let lateBy):
            return "\"\(alarmName)\" is ringing \(Self.humanDuration(lateBy)) late — your phone was unavailable."
        case .skipAndRecordMissed(let lateBy):
            return "\"\(alarmName)\" was missed by \(Self.humanDuration(lateBy)) — your phone was off."
        }
    }

    static func humanDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(hours)h \(remainder)m"
    }
}
