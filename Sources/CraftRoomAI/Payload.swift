import Foundation

/// All fixed geometry of the FLUX.2-klein edit path as baked for the app
/// (Phase A: landscape 3:2 only — every import is cropped/resized to 1248x832
/// so the static CoreML exports and the baked img_ids stay valid).
enum Geo {
    static let photoW = 1248          // VAE encoder input width
    static let photoH = 832           // VAE encoder input height
    static let latH = 104             // photoH / 8  — encoder output rows
    static let latW = 156             // photoW / 8  — encoder output cols
    static let C = 32                 // VAE latent channels
    static let tokenC = 128           // patchified token channels (4 * C)
    static let noiseSide = 48         // noise token grid side; 48*48 = 2304
    static let noiseTokens = 2304
    static let refSideH = 52          // reference token rows (104/2)
    static let refSideW = 78          // reference token cols (156/2); 52*78 = 4056
    static let refTokens = 4056
    static let totalTokens = 6360     // noiseTokens + refTokens
    static let txtTokens = 512
    static let txtDim = 7680
    static let canvas = 768           // decoded image side
}

/// Flat little-endian bins baked by the Python side (bake_app_payload.py;
/// txt_embeds_neg_fp32.bin by bake_txt_embeds_neg.py) and shipped as bundle
/// resources. Byte-wise decode keeps this toolchain-conservative.
struct Payload {
    let sigmas: [Float]        // 31 — FlowMatchEuler; DiT timestep = sigmas[i]
    let txtEmbeds: [Float]     // 512 * 7680 fp32 (cond branch)
    let txtEmbedsNeg: [Float]? // 512 * 7680 fp32 (uncond branch, baked from "")
    let imgIds: [Int32]        // 6360 * 4 int32 (T,H,W,L), replayed verbatim
    let txtIds: [Int32]        // 512 * 4
    let bnMean: [Float]        // 128 — patchified-channel BN stats
    let bnVar: [Float]
    let bnEps: Float

    static func load() throws -> Payload {
        func bin(_ name: String) throws -> [UInt8] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "bin") else {
                throw PipError.missingResource(name)
            }
            return [UInt8](try Data(contentsOf: url, options: .mapped))
        }
        func floats(_ b: [UInt8]) -> [Float] {
            var out = [Float](repeating: 0, count: b.count / 4)
            for i in 0..<out.count {
                let j = i * 4
                let v = UInt32(b[j]) | (UInt32(b[j + 1]) << 8)
                      | (UInt32(b[j + 2]) << 16) | (UInt32(b[j + 3]) << 24)
                out[i] = Float(bitPattern: v)
            }
            return out
        }
        func ints(_ b: [UInt8]) -> [Int32] {
            var out = [Int32](repeating: 0, count: b.count / 4)
            for i in 0..<out.count {
                let j = i * 4
                let v = UInt32(b[j]) | (UInt32(b[j + 1]) << 8)
                      | (UInt32(b[j + 2]) << 16) | (UInt32(b[j + 3]) << 24)
                out[i] = Int32(bitPattern: v)
            }
            return out
        }
        let sig = floats(try bin("sigmas"))
        let eps = floats(try bin("bn_eps"))
        // The CFG uncond bin ships with round-6 payloads; load it leniently so
        // a g1.0-only payload bundle still loads (guidance > 1 then fails at
        // generate-time with a clear message).
        var neg: [Float]?
        if let u = Bundle.main.url(forResource: "txt_embeds_neg_fp32", withExtension: "bin") {
            let v = floats([UInt8](try Data(contentsOf: u, options: .mapped)))
            if v.count == Geo.txtTokens * Geo.txtDim { neg = v }
        }
        let p = Payload(
            sigmas: sig,
            txtEmbeds: floats(try bin("txt_embeds_fp32")),
            txtEmbedsNeg: neg,
            imgIds: ints(try bin("img_ids_land")),
            txtIds: ints(try bin("txt_ids")),
            bnMean: floats(try bin("bn_mean")),
            bnVar: floats(try bin("bn_var")),
            bnEps: eps.first ?? 1e-4)
        guard p.sigmas.count == 31,
              p.txtEmbeds.count == Geo.txtTokens * Geo.txtDim,
              p.imgIds.count == Geo.totalTokens * 4,
              p.txtIds.count == Geo.txtTokens * 4,
              p.bnMean.count == Geo.tokenC, p.bnVar.count == Geo.tokenC
        else { throw PipError.badPayload("bin shape mismatch") }
        return p
    }
}

enum PipError: Error, LocalizedError {
    case missingResource(String)
    case badPayload(String)
    case model(String)
    case image(String)

    var errorDescription: String {
        switch self {
        case .missingResource(let n): return "missing bundled resource: \(n)"
        case .badPayload(let m):      return "payload invalid: \(m)"
        case .model(let m):           return "model error: \(m)"
        case .image(let m):           return "image error: \(m)"
        }
    }
}
