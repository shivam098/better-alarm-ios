import Foundation

/// Counts squat repetitions from a stream of knee-angle observations (PRD M-07).
///
/// The caller supplies angles derived from on-device Vision body-pose estimation;
/// this type holds the rep-counting state machine so it can be unit tested
/// without a camera.
///
/// A repetition only counts when the user goes genuinely low **and** returns to
/// standing. Partial dips and accidental movement are ignored, which is the
/// requirement that "obviously incomplete or accidental movements" are not
/// counted.
public struct SquatRepCounter: Sendable {
    /// Knee angle at or below which the user is considered to be at the bottom.
    public var bottomAngle: Double
    /// Knee angle at or above which the user is considered upright.
    public var standingAngle: Double
    /// Minimum pose confidence required to trust a sample.
    public var minConfidence: Double
    /// A rep faster than this is bouncing, not squatting.
    public var minRepDuration: TimeInterval

    public private(set) var count: Int = 0

    private enum Phase { case standing, descending, atBottom }
    private var phase: Phase = .standing
    private var descentStartedAt: TimeInterval?
    private var lowConfidenceStreak: Int = 0

    public init(
        bottomAngle: Double = 100,
        standingAngle: Double = 160,
        minConfidence: Double = 0.5,
        minRepDuration: TimeInterval = 0.6
    ) {
        self.bottomAngle = bottomAngle
        self.standingAngle = standingAngle
        self.minConfidence = minConfidence
        self.minRepDuration = minRepDuration
    }

    public enum Outcome: Hashable, Sendable {
        case counted(total: Int)
        /// Live coaching so the user knows why a rep did not register (PRD M-07).
        case coaching(String)
        case lowConfidence(String)
        case noChange
    }

    public mutating func consume(
        kneeAngleDegrees: Double,
        confidence: Double,
        at timestamp: TimeInterval
    ) -> Outcome {
        guard confidence >= minConfidence else {
            lowConfidenceStreak += 1
            return .lowConfidence("Move back so your knees are visible")
        }
        lowConfidenceStreak = 0

        switch phase {
        case .standing:
            if kneeAngleDegrees <= bottomAngle {
                phase = .atBottom
                descentStartedAt = timestamp
                return .coaching("Now stand up fully")
            }
            if kneeAngleDegrees < standingAngle {
                phase = .descending
                descentStartedAt = timestamp
                return .coaching("Go lower")
            }
            return .noChange

        case .descending:
            if kneeAngleDegrees <= bottomAngle {
                phase = .atBottom
                return .coaching("Now stand up fully")
            }
            if kneeAngleDegrees >= standingAngle {
                // Came back up without reaching depth — a partial dip.
                phase = .standing
                descentStartedAt = nil
                return .coaching("That wasn't low enough")
            }
            return .noChange

        case .atBottom:
            guard kneeAngleDegrees >= standingAngle else { return .noChange }

            // Completed the full range. Guard against bouncing.
            if let start = descentStartedAt, timestamp - start < minRepDuration {
                phase = .standing
                descentStartedAt = nil
                return .coaching("Slow down — that was too quick to count")
            }

            phase = .standing
            descentStartedAt = nil
            count += 1
            return .counted(total: count)
        }
    }

    public func progress(target: Int) -> MissionProgress {
        MissionProgress(current: count, target: target, unit: "squats")
    }

    public mutating func reset() {
        count = 0
        phase = .standing
        descentStartedAt = nil
        lowConfidenceStreak = 0
    }
}
