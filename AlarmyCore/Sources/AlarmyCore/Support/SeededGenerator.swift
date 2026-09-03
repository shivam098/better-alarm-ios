import Foundation

/// Deterministic, seedable RNG (SplitMix64).
///
/// Used so that generated challenges can be reproduced exactly in tests while
/// remaining unpredictable in production.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        // Avoid the degenerate all-zero state.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public extension SeededGenerator {
    /// Seed derived from an occurrence so a given alarm instance is reproducible
    /// for diagnostics, but differs between mornings.
    init(occurrence key: String, salt: UInt64 = 0) {
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001B3
        }
        self.init(seed: hash ^ salt)
    }
}
