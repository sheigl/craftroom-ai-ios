import Foundation

/// Seedable splitmix64 PRNG + Box–Muller gaussian, used for the initial
/// latent noise (`latents = randn * init_noise_sigma`).
///
/// Deterministic per seed, identical on device and in tests: the ladder's
/// per-cell comparisons must only differ in compute units / steps / model
/// variant, never in the noise.
public struct SeededGaussian {
    public struct SplitMix64 {
        public var state: UInt64

        public init(state: UInt64) { self.state = state }

        public mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97C449D57
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF585C50C2323B3F
            z = (z ^ (z >> 27)) &* 0x94D049BB3FC14DC5
            return z ^ (z >> 31)
        }
    }

    private var sm: SplitMix64
    private var spare: Float?

    public init(seed: UInt64) { sm = SplitMix64(state: seed) }

    /// Uniform [0, 1) with 53-bit resolution.
    public mutating func unit() -> Double {
        Double(sm.next() >> 11) / 9007199254740992.0
    }

    /// Standard normal sample.
    public mutating func next() -> Float {
        if let s = spare { spare = nil; return s }
        var u1 = unit()
        let u2 = unit()
        if u1 < 1e-12 { u1 = 1e-12 }
        let r = (-2.0 * log(u1)).squareRoot()
        let th = 2.0 * Double.pi * u2
        spare = Float(r * sin(th))
        return Float(r * cos(th))
    }

    /// `count` standard normals.
    public mutating func fill(_ count: Int, scale: Float = 1) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = next() * scale }
        return out
    }
}
