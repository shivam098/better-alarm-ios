import Foundation

/// A single device-motion reading, normalised so the core library never has to
/// import CoreMotion and can therefore be tested with synthetic data.
public struct MotionSample: Hashable, Sendable {
    /// Seconds on a monotonic timeline.
    public let timestamp: TimeInterval
    /// User acceleration in g, gravity already removed.
    public let x: Double
    public let y: Double
    public let z: Double
    /// Magnitude of the rotation rate in rad/s.
    public let rotationRate: Double

    public init(timestamp: TimeInterval, x: Double, y: Double, z: Double, rotationRate: Double = 0) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.z = z
        self.rotationRate = rotationRate
    }

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    /// Sign of the largest-magnitude axis, used for reversal detection.
    public var dominantAxisIsPositive: Bool {
        let ax = abs(x), ay = abs(y), az = abs(z)
        if ax >= ay && ax >= az { return x >= 0 }
        if ay >= az { return y >= 0 }
        return z >= 0
    }
}

enum MotionStatistics {
    /// Coefficient of variation: standard deviation divided by the mean.
    /// Near zero means near-perfectly periodic, which a human cannot produce.
    static func coefficientOfVariation(_ values: [TimeInterval]) -> Double {
        guard values.count > 1 else { return .infinity }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return .infinity }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot() / mean
    }
}
