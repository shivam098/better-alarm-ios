import Foundation

/// Day of week, using the same numbering as `Calendar` (1 = Sunday ... 7 = Saturday).
public enum Weekday: Int, Codable, Hashable, CaseIterable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public var calendarValue: Int { rawValue }

    public static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Set<Weekday> = [.saturday, .sunday]

    public var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }
}

public extension Set where Element == Weekday {
    /// Human summary used in the alarm list ("Weekdays", "Mon, Wed, Fri", ...).
    var summary: String {
        if isEmpty { return "Once" }
        if count == 7 { return "Every day" }
        if self == Weekday.weekdays { return "Weekdays" }
        if self == Weekday.weekend { return "Weekends" }
        return Weekday.allCases
            .filter { contains($0) }
            .map(\.shortName)
            .joined(separator: ", ")
    }
}
