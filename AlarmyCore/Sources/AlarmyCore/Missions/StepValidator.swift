import Foundation

/// Validates walking-mission progress (PRD M-06).
///
/// The anti-cheat rules this type enforces:
///
/// * **Steps banked before the alarm never count** (PRD E29). The first reading
///   only establishes a baseline; the validator credits deltas measured from
///   that point on. This is why the app streams live pedometer updates instead
///   of querying historical step counts.
/// * **Implausible bursts are rejected** — a human cannot produce more than a
///   few steps per second, so a sudden jump is not gait.
/// * **Cadence is cross-checked against device motion** (PRD E30, MSN-INT-2).
///   Waving the phone around produces a cadence outside the human walking band
///   and is not credited.
public struct StepValidator: Sendable {
    public let target: Int
    public var maxStepsPerSecond: Double
    public var gaitCadenceRange: ClosedRange<Double>

    public private(set) var validatedSteps: Int = 0
    public private(set) var rejectedSamples: Int = 0

    private var lastCumulative: Int?
    private var lastTimestamp: TimeInterval?

    public init(
        target: Int,
        maxStepsPerSecond: Double = 4.0,
        gaitCadenceRange: ClosedRange<Double> = 0.5...3.5
    ) {
        self.target = target
        self.maxStepsPerSecond = maxStepsPerSecond
        self.gaitCadenceRange = gaitCadenceRange
    }

    public enum Outcome: Hashable, Sendable {
        /// First reading — establishes the zero point, credits nothing.
        case baselineEstablished
        case credited(steps: Int, total: Int)
        case rejected(MissionFailure)
        case noChange
    }

    public mutating func ingest(
        cumulativeSteps: Int,
        at timestamp: TimeInterval,
        cadenceHz: Double? = nil
    ) -> Outcome {
        guard let previousCumulative = lastCumulative, let previousTimestamp = lastTimestamp else {
            lastCumulative = cumulativeSteps
            lastTimestamp = timestamp
            return .baselineEstablished
        }

        let delta = cumulativeSteps - previousCumulative
        let elapsed = timestamp - previousTimestamp

        guard delta > 0 else {
            // Progress holds rather than resetting when the user pauses.
            lastTimestamp = timestamp
            return .noChange
        }

        if elapsed > 0 {
            let rate = Double(delta) / elapsed
            if rate > maxStepsPerSecond {
                rejectedSamples += 1
                lastCumulative = cumulativeSteps
                lastTimestamp = timestamp
                return .rejected(.movementNotDetected)
            }
        }

        if let cadence = cadenceHz, !gaitCadenceRange.contains(cadence) {
            rejectedSamples += 1
            lastCumulative = cumulativeSteps
            lastTimestamp = timestamp
            return .rejected(.movementNotDetected)
        }

        validatedSteps += delta
        lastCumulative = cumulativeSteps
        lastTimestamp = timestamp
        return .credited(steps: delta, total: validatedSteps)
    }

    public var isComplete: Bool { validatedSteps >= target }

    public var progress: MissionProgress {
        MissionProgress(current: min(validatedSteps, target), target: target, unit: "steps")
    }
}
