import Foundation

/// Counts shakes from raw motion samples (PRD M-05).
///
/// Layered verification, per PRD MSN-INT-2 (never rely on one signal):
///
/// 1. Acceleration must exceed a threshold.
/// 2. The dominant axis must *reverse* direction — a single lurch is not a shake.
/// 3. A refractory period stops one violent movement registering many times.
/// 4. A rotational component must be present, because a real wrist shake rotates
///    the device. Sliding the phone along a surface does not.
/// 5. Near-perfectly periodic timing is rejected as mechanical: a human cannot
///    shake with the regularity of a machine or a rigged setup.
public struct ShakeCounter: Sendable {
    /// Acceleration magnitude in g required to consider a sample.
    public var threshold: Double
    /// Minimum gap between two counted shakes.
    public var refractory: TimeInterval
    /// Minimum rotation in rad/s.
    public var minRotationRate: Double
    /// Coefficient-of-variation floor below which motion is treated as mechanical.
    public var mechanicalVariationFloor: Double
    /// Intervals needed before the periodicity test is meaningful.
    public var mechanicalSampleCount: Int

    public private(set) var count: Int = 0
    public private(set) var mechanicalMotionDetected = false

    private var lastCountedAt: TimeInterval?
    private var lastDominantPositive: Bool?
    private var intervals: [TimeInterval] = []

    public init(
        threshold: Double = 1.8,
        refractory: TimeInterval = 0.18,
        minRotationRate: Double = 0.6,
        mechanicalVariationFloor: Double = 0.05,
        mechanicalSampleCount: Int = 8
    ) {
        self.threshold = threshold
        self.refractory = refractory
        self.minRotationRate = minRotationRate
        self.mechanicalVariationFloor = mechanicalVariationFloor
        self.mechanicalSampleCount = mechanicalSampleCount
    }

    public enum Outcome: Hashable, Sendable {
        case counted(total: Int)
        case ignored
        /// Progress was reset because the motion looked automated.
        case rejectedMechanical
    }

    public mutating func consume(_ sample: MotionSample) -> Outcome {
        guard sample.magnitude >= threshold else { return .ignored }
        guard sample.rotationRate >= minRotationRate else { return .ignored }

        if let last = lastCountedAt, sample.timestamp - last < refractory {
            return .ignored
        }

        // A shake is a reversal, not a push.
        if let previousSign = lastDominantPositive, previousSign == sample.dominantAxisIsPositive {
            return .ignored
        }

        if let last = lastCountedAt {
            intervals.append(sample.timestamp - last)
            if intervals.count > mechanicalSampleCount * 2 {
                intervals.removeFirst()
            }
        }

        lastCountedAt = sample.timestamp
        lastDominantPositive = sample.dominantAxisIsPositive
        count += 1

        if intervals.count >= mechanicalSampleCount,
           MotionStatistics.coefficientOfVariation(intervals) < mechanicalVariationFloor {
            mechanicalMotionDetected = true
            count = 0
            intervals.removeAll()
            return .rejectedMechanical
        }

        return .counted(total: count)
    }

    public func progress(target: Int) -> MissionProgress {
        MissionProgress(current: count, target: target, unit: "shakes")
    }

    public mutating func reset() {
        count = 0
        lastCountedAt = nil
        lastDominantPositive = nil
        intervals.removeAll()
        mechanicalMotionDetected = false
    }
}
