import CoreML
import UIKit

enum ComputeUnitsOption: String, CaseIterable, Identifiable {
    case all = "All (ANE+GPU)"
    case cpuAndGPU = "CPU+GPU"
    case cpuOnly = "CPU only"

    var id: String { rawValue }

    var pref: MLComputeUnits {
        switch self {
        case .all:        return .all
        case .cpuAndGPU:  return .cpuAndGPU
        case .cpuOnly:    return .cpuOnly
        }
    }
}

struct RunStats {
    var modelLoad: Double = 0
    var prep: Double = 0
    var encode: Double = 0
    var loop: Double = 0
    var decode: Double = 0
    var total: Double = 0
    var stepMillis: [Double] = []
    var peakMemMB: Double = 0
    var units: String = ""
    var guidance: Float = 1.0
    var forwards: Int = 30
}

/// The full edit-path pipeline. Guidance 1.0 runs one DiT forward per step
/// (30 forwards); guidance > 1 runs the pipeline's true-CFG pair (cond with
/// the baked prompt embeds, uncond with the baked "" embeds, 60 forwards) and
/// combines exactly as pipeline_flux2_klein.py does:
///   v = uncond + g * (cond - uncond)
/// The ladder verdict ships guidance 3.0 (2.0 fallback); the picker lets the
/// on-device run measure 1.0 vs 3.0 on the same photo. Every number reproduced
/// from the diffusers pipeline source and the desktop2 reference runs:
///   encode  -> patchify (c' = 4c + 2dy + dx, row-major tokens) -> BN normalize
///   loop    -> hidden = [noise 2304 | ref 4056]; v = model(...)[:, 0:2304]
///            -> noise += (sigmas[i+1] - sigmas[i]) * v ; ref stays pinned
///   decode  -> BN denormalize -> unpatchify -> vae_decoder -> [-1,1] image
final class Inference {
    let payload: Payload
    private var dit: MLModel?
    private var vaeEnc: MLModel?
    private var vaeDec: MLModel?

    init() throws {
        payload = try Payload.load()
    }

    // MARK: models

    @discardableResult
    func loadModels(units: ComputeUnitsOption) throws -> Double {
        let t0 = Date()
        dit = try Inference.loadModel(named: "dit_int8", units: units.pref)
        vaeEnc = try Inference.loadModel(named: "vae_encoder_land_1248x832", units: units.pref)
        vaeDec = try Inference.loadModel(named: "vae_decoder", units: units.pref)
        return Date().timeIntervalSince(t0)
    }

    static func loadModel(named: String, units: MLComputeUnits) throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        // Xcode precompiles bundled .mlpackage files into .mlmodelc; fall back
        // to on-device compilation if the bundle carries the raw package.
        if let u = Bundle.main.url(forResource: named, withExtension: "mlmodelc") {
            return try MLModel(contentsOf: u, configuration: cfg)
        }
        if let u = Bundle.main.url(forResource: named, withExtension: "mlpackage") {
            // compileModel is async-only in the current SDK; block on a
            // semaphore (loadModels is always called off the main thread —
            // see Engine.run via Task.detached).
            var result: Result<URL, Error>?
            let sem = DispatchSemaphore(value: 0)
            MLModel.compileModel(at: u) { r in
                result = r
                sem.signal()
            }
            sem.wait()
            guard let result else { throw PipError.model("compileModel: no result for \(named)") }
            return try MLModel(contentsOf: try result.get(), configuration: cfg)
        }
        throw PipError.model("not found in bundle: \(named)")
    }

    // MARK: MLMultiArray helpers

    static func f32(_ shape: [Int], _ src: [Float]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        guard a.count == src.count else { throw PipError.badPayload("f32 fill \(a.count) != \(src.count)") }
        let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
        for i in 0..<src.count { p[i] = src[i] }
        return a
    }

    static func i32(_ shape: [Int], _ src: [Int32]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
        guard a.count == src.count else { throw PipError.badPayload("i32 fill \(a.count) != \(src.count)") }
        let p = a.dataPointer.bindMemory(to: Int32.self, capacity: a.count)
        for i in 0..<src.count { p[i] = src[i] }
        return a
    }

    static func fp32Copy(_ a: MLMultiArray) throws -> [Float] {
        let n = a.count
        var out = [Float](repeating: 0, count: n)
        // The DiT ships FLOAT16 output (per the dumped spec); the VAEs ship
        // FLOAT32. Convert manually — no withType-style API on MLMultiArray.
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { out[i] = p[i] }
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: n)
            for i in 0..<n { out[i] = Float(p[i]) }
        case .int32:
            let p = a.dataPointer.bindMemory(to: Int32.self, capacity: n)
            for i in 0..<n { out[i] = Float(p[i]) }
        default:
            throw PipError.model("unsupported MLMultiArray dataType \(a.dataType)")
        }
        return out
    }

    static func predict(_ model: MLModel, _ arrays: [String: MLMultiArray]) throws -> [Float] {
        var items: [String: MLFeatureValue] = [:]
        for (name, arr) in arrays { items[name] = MLFeatureValue(multiArray: arr) }
        let provider = try MLDictionaryFeatureProvider(dictionary: items)
        let out = try model.prediction(from: provider)
        guard let outName = model.modelDescription.outputDescriptionsByName.keys.first,
              let fv = out.featureValue(for: outName),
              let ma = fv.multiArrayValue else {
            throw PipError.model("\(type(of: model)): no multiarray output")
        }
        return try fp32Copy(ma)
    }

    // MARK: reference encode

    /// photo pixels (CHW, 3 x photoH x photoW, [-1,1]) -> BN-normalized ref
    /// tokens (4056 x 128).
    func encodeReference(_ pixels: [Float]) throws -> [Float] {
        guard let vaeEnc = vaeEnc else { throw PipError.model("encoder not loaded") }
        let x = try Inference.f32([1, 3, Geo.photoH, Geo.photoW], pixels)
        let lat = try Inference.predict(vaeEnc, ["x": x])
        guard lat.count == Geo.C * Geo.latH * Geo.latW else {
            throw PipError.model("encoder out \(lat.count)")
        }
        // patchify + BN normalize (mirrors _encode_vae_image)
        var ref = [Float](repeating: 0, count: Geo.refTokens * Geo.tokenC)
        let eps = payload.bnEps
        for c in 0..<Geo.C {
            for h2 in 0..<Geo.refSideH {
                for w2 in 0..<Geo.refSideW {
                    for dy in 0..<2 {
                        let srcRow = (h2 * 2 + dy) * Geo.latW
                        for dx in 0..<2 {
                            let c2 = 4 * c + 2 * dy + dx
                            let src = c * (Geo.latH * Geo.latW) + srcRow + (w2 * 2 + dx)
                            let dst = ((h2 * Geo.refSideW) + w2) * Geo.tokenC + c2
                            let z = lat[src]
                            ref[dst] = (z - payload.bnMean[c2]) / sqrt(payload.bnVar[c2] + eps)
                        }
                    }
                }
            }
        }
        return ref
    }

    // MARK: the 30-step loop

    func denoise(noise: inout [Float], ref: [Float], hidden: MLMultiArray,
                 ehs: MLMultiArray, ehsNeg: MLMultiArray?, guidance: Float,
                 imgIds: MLMultiArray, txtIds: MLMultiArray,
                 stats: inout RunStats) throws {
        guard let dit = dit else { throw PipError.model("dit not loaded") }
        let hp = hidden.dataPointer.bindMemory(to: Float.self, capacity: hidden.count)
        let noiseCount = Geo.noiseTokens * Geo.tokenC
        // reference block never changes — write it once
        for i in 0..<ref.count { hp[noiseCount + i] = ref[i] }
        let ts = try Inference.f32([1], [payload.sigmas[0]])
        let tsp = ts.dataPointer.bindMemory(to: Float.self, capacity: 1)
        let cfg = guidance > 1 && ehsNeg != nil

        var stepMemPeak: UInt64 = 0
        stats.stepMillis.removeAll(keepingCapacity: true)
        for i in 0..<30 {
            let t0 = Date()
            for k in 0..<noiseCount { hp[k] = noise[k] }
            tsp[0] = payload.sigmas[i]
            // cond branch
            let cond = try Inference.predict(dit, [
                "hidden_states": hidden,
                "encoder_hidden_states": ehs,
                "timestep": ts,
                "img_ids": imgIds,
                "txt_ids": txtIds,
            ])
            guard cond.count == hidden.count else {
                throw PipError.model("dit out \(cond.count) != \(hidden.count)")
            }
            let dt = payload.sigmas[i + 1] - payload.sigmas[i]
            if cfg, let ehsNeg {
                // uncond branch — same latent/timestep/ids, baked "" embeds
                let uncond = try Inference.predict(dit, [
                    "hidden_states": hidden,
                    "encoder_hidden_states": ehsNeg,
                    "timestep": ts,
                    "img_ids": imgIds,
                    "txt_ids": txtIds,
                ])
                guard uncond.count == hidden.count else {
                    throw PipError.model("dit uncond out \(uncond.count)")
                }
                // pipeline_flux2_klein.py true-CFG combine (sliced noise block)
                for k in 0..<noiseCount {
                    noise[k] += dt * (uncond[k] + guidance * (cond[k] - uncond[k]))
                }
            } else {
                for k in 0..<noiseCount { noise[k] += dt * cond[k] }
            }
            stats.stepMillis.append(Date().timeIntervalSince(t0) * 1000)
            stepMemPeak = max(stepMemPeak, currentFootprint())
        }
        stats.peakMemMB = max(stats.peakMemMB, Double(stepMemPeak) / 1_048_576.0)
    }

    // MARK: decode

    func decodeToImage(_ noise: [Float]) throws -> UIImage {
        guard let vaeDec = vaeDec else { throw PipError.model("decoder not loaded") }
        let eps = payload.bnEps
        var lat = [Float](repeating: 0, count: Geo.C * Geo.noiseSide * 2 * (Geo.noiseSide * 2))
        let side = Geo.noiseSide * 2   // 96
        // BN denormalize + unpatchify (inverse of _encode_vae_image patchify)
        for t in 0..<Geo.noiseTokens {
            let h2 = t / Geo.noiseSide
            let w2 = t % Geo.noiseSide
            for c2 in 0..<Geo.tokenC {
                let z = noise[t * Geo.tokenC + c2]
                let c = c2 / 4, dy = (c2 / 2) % 2, dx = c2 % 2
                let denorm = z * sqrt(payload.bnVar[c2] + eps) + payload.bnMean[c2]
                lat[(c * side + (2 * h2 + dy)) * side + (2 * w2 + dx)] = denorm
            }
        }
        let z = try Inference.f32([1, Geo.C, side, side], lat)
        let img = try Inference.predict(vaeDec, ["z": z])
        guard img.count == 3 * Geo.canvas * Geo.canvas else {
            throw PipError.model("decoder out \(img.count)")
        }
        return try Inference.uiImage(rgbPlanar: img)
    }

    static func uiImage(rgbPlanar planar: [Float]) throws -> UIImage {
        let w = Geo.canvas, h = Geo.canvas, wh = w * h
        // 32BitLittle + alphaNone: memory byte order per pixel is B,G,R,A.
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<wh {
            func ch8(_ v: Float) -> UInt8 {
                let s = max(0, min(1, (v + 1) * 0.5))
                return UInt8((s * 255).rounded())
            }
            bytes[i * 4 + 0] = ch8(planar[2 * wh + i])   // B
            bytes[i * 4 + 1] = ch8(planar[wh + i])       // G
            bytes[i * 4 + 2] = ch8(planar[i])            // R
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: [.byteOrder32Little,
                                               CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]) else {
            throw PipError.image("no bitmap context")
        }
        guard let cg = ctx.makeImage() else { throw PipError.image("no CGImage") }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    // MARK: run

    func generate(from image: UIImage, seed: UInt64, guidance: Float = 3.0,
                  onStage: ((String) -> Void)? = nil) throws -> (UIImage, RunStats) {
        var s = RunStats()
        let t0 = Date()
        var memPeak: UInt64 = currentFootprint()

        // guidance > 1 needs the baked uncond embeds (txt_embeds_neg_fp32.bin)
        var ehsNeg: MLMultiArray?
        if guidance > 1 {
            guard let neg = payload.txtEmbedsNeg else {
                throw PipError.badPayload("txt_embeds_neg_fp32.bin missing — guidance > 1 unavailable")
            }
            ehsNeg = try Inference.f32([1, Geo.txtTokens, Geo.txtDim], neg)
        }
        s.guidance = guidance

        onStage?("Preparing pixels…")
        let tPrep0 = Date()
        let pixels = try ImageUtils.normalizedPixels(image)   // CHW [-1,1]
        let hidden = try MLMultiArray(shape: [1, Geo.totalTokens, Geo.tokenC].map { NSNumber(value: $0) },
                                       dataType: .float32)
        let ehs = try Inference.f32([1, Geo.txtTokens, Geo.txtDim], payload.txtEmbeds)
        let imgA = try Inference.i32([1, Geo.totalTokens, 4], payload.imgIds)
        let txtA = try Inference.i32([1, Geo.txtTokens, 4], payload.txtIds)
        s.prep = Date().timeIntervalSince(tPrep0)

        onStage?("VAE encode (reference)…")
        let tEnc0 = Date()
        let ref = try encodeReference(pixels)
        s.encode = Date().timeIntervalSince(tEnc0)

        var noise = [Float](repeating: 0, count: Geo.noiseTokens * Geo.tokenC)
        var g = Gauss(seed: seed)
        for k in 0..<noise.count { noise[k] = g.next() }

        let fwd = (guidance > 1 && ehsNeg != nil) ? 60 : 30
        s.forwards = fwd
        onStage?("Diffusion loop (\(fwd) forwards, guidance \(String(format: "%.1f", guidance)))…")
        let tLoop0 = Date()
        try denoise(noise: &noise, ref: ref, hidden: hidden, ehs: ehs,
                    ehsNeg: ehsNeg, guidance: guidance,
                    imgIds: imgA, txtIds: txtA, stats: &s)
        s.loop = Date().timeIntervalSince(tLoop0)

        onStage?("VAE decode…")
        let tDec0 = Date()
        let out = try decodeToImage(noise)
        s.decode = Date().timeIntervalSince(tDec0)

        memPeak = max(memPeak, currentFootprint())
        s.peakMemMB = max(s.peakMemMB, Double(memPeak) / 1_048_576.0)
        s.total = Date().timeIntervalSince(t0)
        return (out, s)
    }
}
