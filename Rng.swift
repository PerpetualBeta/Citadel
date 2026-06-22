// Citadel — deterministic seeded RNG.
//
// Citadel is 100% procedural; every level is generated from a seed so a run is
// reproducible (and so the smoke test / screenshot harness can pin a known
// layout). SplitMix64 — fast, good distribution, tiny state. We conform to
// RandomNumberGenerator so the stdlib's `.random(in:using:)` work too.

import Foundation

struct Rng: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Float in [lo, hi).
    mutating func f(_ lo: Float = 0, _ hi: Float = 1) -> Float {
        let u = Float(next() >> 40) / Float(1 << 24)   // 24-bit mantissa precision
        return lo + (hi - lo) * u
    }

    /// Int in [lo, hi] inclusive.
    mutating func i(_ lo: Int, _ hi: Int) -> Int {
        if hi <= lo { return lo }
        let span = UInt64(hi - lo + 1)
        return lo + Int(next() % span)
    }

    /// True with probability `p` (0…1).
    mutating func chance(_ p: Float) -> Bool { f() < p }

    /// Pick a random element.
    mutating func pick<T>(_ arr: [T]) -> T { arr[i(0, arr.count - 1)] }
}
