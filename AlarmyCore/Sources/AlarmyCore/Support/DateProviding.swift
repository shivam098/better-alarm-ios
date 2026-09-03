import Foundation

/// Injectable wall-clock time source.
///
/// Named `DateProviding` rather than `Clock` to avoid colliding with the
/// standard library's `Clock` protocol.
public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProviding {
    public init() {}
    public var now: Date { Date() }
}

/// Fixed clock for deterministic tests.
public final class FixedDateProvider: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    public init(_ now: Date) { self._now = now }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        _now = date
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(interval)
    }
}

/// Monotonic elapsed-time source that cannot be moved by changing the system clock.
///
/// Satisfies MSN-INT-4: a user who sets the device clock forward must not be able
/// to fast-forward a snooze or resolve a ringing alarm.
public protocol MonotonicTimeProviding: Sendable {
    /// Seconds since an arbitrary fixed reference point. Only differences are meaningful.
    var uptime: TimeInterval { get }
}

public struct SystemMonotonicTime: MonotonicTimeProviding {
    public init() {}
    public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public final class FixedMonotonicTime: MonotonicTimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _uptime: TimeInterval

    public init(_ uptime: TimeInterval = 0) { self._uptime = uptime }

    public var uptime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _uptime
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _uptime += interval
    }
}
