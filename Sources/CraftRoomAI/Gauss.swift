/// Seedable splitmix64 PRNG + Box–Muller gaussian, for the raw-noise init
/// (Phase A default seed 0; matches the reference eval recipe).
import Foundation

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97C449D57
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF585C50C2323B3F
        z = (z ^ (z >> 27)) &* 0x94D049BB3FC14DC5
        return z ^ (z >> 31)
    }
}

struct Gauss {
    var sm: SplitMix64
    var spare: Float?

    init(seed: UInt64) { sm = SplitMix64(state: seed) }

    mutating func unit() -> Double {
        Double(sm.next() >> 11) / 9007199254740992.0   // [0,1), 53-bit
    }

    mutating func next() -> Float {
        if let s = spare { spare = nil; return s }
        var u1 = unit()
        let u2 = unit()
        if u1 < 1e-12 { u1 = 1e-12 }
        let r = sqrt(-2.0 * log(u1))
        let th = 2.0 * Double.pi * u2
        spare = Float(r * sin(th))
        return Float(r * cos(th))
    }
}
