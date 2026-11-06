import Foundation

/// The baked `EulerDiscreteScheduler` schedule the frozen student was
/// evaluated with (30 steps, epsilon prediction, leading spacing).
///
/// The bin is produced on the Linux box by
/// `sdxl/teacher/device_v2/bake_euler_scheduler.py` from diffusers itself, so
/// the device schedule *is* the eval schedule; the probe record in this repo
/// (`sdxl/teacher/device_v2_euler_scheduler.json`) pins the numbers.
///
/// Layout (version 1, little endian):
///
///     "CRES" | u32 version | u32 steps | u32 nSigma
///     | nSigma * f32 sigmas | steps * f32 timesteps
///
/// The harness update is `x += (sigma[i + 1] - sigma[i]) * eps`, and the
/// initial latent is `randn * initNoiseSigma` (= sigma[0]).
public struct EulerScheduler: Equatable {
    public static let expectedMagic: [UInt8] = Array("CRES".utf8)
    public static let supportedVersion: UInt32 = 1

    public let steps: Int
    /// `steps + 1` sigmas; `sigmas[steps] == 0`.
    public let sigmas: [Float]
    /// Integer timesteps (<= 1000, so exact in fp16).
    public let timesteps: [Float]

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case tooShort(bytes: Int)
        case badMagic
        case unsupportedVersion(UInt32)
        case inconsistent(steps: Int, sigmaCount: Int, bytes: Int)

        public var description: String {
            switch self {
            case .tooShort(let n): return "scheduler bin too short (\(n) B)"
            case .badMagic: return "scheduler bin: bad magic (expected CRES)"
            case .unsupportedVersion(let v): return "scheduler bin: version \(v) unsupported"
            case .inconsistent(let s, let n, let b):
                return "scheduler bin: steps \(s), sigmas \(n), \(b) B is inconsistent"
            }
        }
    }

    public init(steps: Int, sigmas: [Float], timesteps: [Float]) throws {
        guard steps > 0, sigmas.count == steps + 1, timesteps.count == steps else {
            throw LoadError.inconsistent(steps: steps, sigmaCount: sigmas.count,
                                         bytes: 0)
        }
        self.steps = steps
        self.sigmas = sigmas
        self.timesteps = timesteps
    }

    public init(data: Data) throws {
        let headerBytes = 16
        guard data.count >= headerBytes else { throw LoadError.tooShort(bytes: data.count) }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == Self.expectedMagic else { throw LoadError.badMagic }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        func f32(_ offset: Int) -> Float {
            Float(bitPattern: u32(offset))
        }
        let version = u32(4)
        guard version == Self.supportedVersion else {
            throw LoadError.unsupportedVersion(version)
        }
        let steps = Int(u32(8))
        let nSigma = Int(u32(12))
        let expected = headerBytes + 4 * (nSigma + steps)
        guard steps > 0, nSigma == steps + 1, data.count == expected else {
            throw LoadError.inconsistent(steps: steps, sigmaCount: nSigma,
                                         bytes: data.count)
        }
        var sigmas = [Float](repeating: 0, count: nSigma)
        for i in 0..<nSigma { sigmas[i] = f32(headerBytes + 4 * i) }
        var timesteps = [Float](repeating: 0, count: steps)
        for i in 0..<steps { timesteps[i] = f32(headerBytes + 4 * (nSigma + i)) }
        self.steps = steps
        self.sigmas = sigmas
        self.timesteps = timesteps
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .alwaysMapped))
    }

    /// The bin shipped inside this package (the app reads it through
    /// `CraftRoomCore`, the tests verify it against the numpy golden).
    public static func bundled() throws -> EulerScheduler {
        guard let url = Bundle.module.url(forResource: "euler_scheduler_v2",
                                         withExtension: "bin") else {
            throw LoadError.tooShort(bytes: 0)
        }
        return try EulerScheduler(contentsOf: url)
    }

    /// sigma[0] is the largest sigma for this schedule, i.e. diffusers'
    /// `init_noise_sigma`: `latents = randn * init_noise_sigma`.
    public var initNoiseSigma: Float { sigmas[0] }

    /// One Euler step, in place: `x += (sigma[i+1] - sigma[i]) * eps`.
    /// Returns the dt used (ms-scale bookkeeping in the harness logs).
    @discardableResult
    public func step(_ x: inout [Float], eps: [Float], index: Int) -> Float {
        let dt = sigmas[index + 1] - sigmas[index]
        let n = min(x.count, eps.count)
        x.withUnsafeMutableBufferPointer { dst in
            eps.withUnsafeBufferPointer { src in
                for i in 0..<n { dst[i] += dt * src[i] }
            }
        }
        return dt
    }

    /// The full schedule applied to a whole eps table (used by the unit test
    /// and by `--dry` runs); `eps` is `steps` rows of `n` values.
    public func run(x0: [Float], eps: [Float], latents n: Int) -> [Float] {
        var x = x0
        for i in 0..<steps {
            let row = Array(eps[(i * n)..<((i + 1) * n)])
            step(&x, eps: row, index: i)
        }
        return x
    }
}
