import CoreML
import UIKit
import CraftRoomCore

/// Compute-unit sets the ladder measures.
enum ComputeUnitsOption: String, CaseIterable, Identifiable {
    /// "all" = ANE + GPU + CPU (Core ML's own scheduling).
    case all = "all"
    case cpuAndNeuralEngine = "cpuAndNeuralEngine"
    case cpuOnly = "cpuOnly"

    var id: String { rawValue }

    var pref: MLComputeUnits {
        switch self {
        case .all:               return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuOnly:            return .cpuOnly
        }
    }

    var label: String {
        switch self {
        case .all: return "All (ANE+GPU)"
        case .cpuAndNeuralEngine: return "ANE+CPU"
        case .cpuOnly: return "CPU only"
        }
    }
}

/// The two numerically identical UNet exports (contract §6.4): SDPA is the
/// shipping candidate, split_einsum is the apple-style per-head attention
/// layout built for the A/B.
enum AttentionVariant: String, CaseIterable, Identifiable {
    case sdpa
    case splitEinsum = "split_einsum"

    var id: String { rawValue }

    var modelName: String {
        switch self {
        case .sdpa: return "Unet_ControlNet_canny1200_6bit"
        case .splitEinsum: return "Unet_ControlNet_canny1200_split_einsum_6bit"
        }
    }

    var label: String {
        switch self {
        case .sdpa: return "SDPA"
        case .splitEinsum: return "split_einsum"
        }
    }
}

struct RunStats {
    var modelLoad: Double = 0
    var prep: Double = 0
    var encode: Double = 0        // canny + conditioning (no VAE encode on this path)
    var loop: Double = 0
    var decode: Double = 0
    var total: Double = 0
    var stepMillis: [Double] = []
    var peakMemMB: Double = 0
    var units: String = ""
    var variant: String = ""
    var steps: Int = 30
    var canvas: String = "768x768"
    var forwards: Int { max(stepMillis.count, 1) }
}

/// The v0.5 device-v2 pipeline: `canny_edge_v1` → one combined
/// UNet+ControlNet forward per step (batch 2 = positive+negative rows) →
/// Euler steps → VAE decode → crop back to the source aspect.
///
/// Contract-exact details (T1/T2/T3, `device_v2_inference_contract.md` §5–§6):
///
///  * `controlnet_cond` 2×3×768×768 fp16, the canny mask centred in the
///    square with the rest zero (no border is ever drawn);
///  * `time_ids` `[768, 768, 0, 0, 768, 768]` for both rows — orig == target ==
///    bucket, exactly how every graded page was scored; the real photo size is
///    deliberately not used (untested micro-conditioning regime);
///  * `sample` starts at `randn * sigma[0]`, identical in both rows;
///  * CFG is harness-side: `eps = noise[neg] + 9 · (noise[pos] − noise[neg])`;
///  * Euler: `latents += (sigma[i+1] − sigma[i]) · eps`;
///  * VAE decode is **fp32 on cpuAndGPU** (the NE has no fp32 compute type);
///  * the decoded 768² frame is cropped back to the content rect.
final class Inference {
    private var unet: MLModel?
    private var vaeDec: MLModel?
    private var ehs: MLMultiArray?
    private var txtEmbeds: MLMultiArray?
    private var timeIds: MLMultiArray?
    private var scheduler: EulerScheduler?
    private var variant: AttentionVariant = .sdpa
    private(set) var effectiveUnits: ComputeUnitsOption = .all

    init() {}

    /// Loads the variant's UNet (requested units) and the fp32 VAE decoder
    /// (`cpuAndGPU` by design — see contract §6.2).
    ///
    /// Build 10 instrumentation, because build 9 died *inside* the UNet load and
    /// left nothing after its `load:` line:
    ///
    ///  * every load line goes to telemetry as well as `phaseA.log`;
    ///  * `weights` now means **this variant's** weight files, not every
    ///    `weight.bin` on disk (an old device-v1 payload left in Application
    ///    Support inflated build 9's line by ~3.9 GB);
    ///  * `estimate` is the CPU-backend de-quantized fp16 figure from
    ///    `MemoryPreflight` — what a `cpuOnly` load really costs;
    ///  * a `LoadWatchdog` logs `load in flight …` every 2 s across each
    ///    blocking `MLModel(contentsOf:)`, which is the line that survives a
    ///    jetsam kill.
    @discardableResult
    func loadModels(units: ComputeUnitsOption, variant: AttentionVariant,
                    force: Bool = true) throws -> Double {
        let t0 = Date()
        let weightsMB = Double(PayloadStore.shared.variantWeightBytes) / 1_048_576.0
        let headroom = Diagnostics.availableMemoryMB()
        let headText = headroom.map { String(format: "%.0f", $0) } ?? "n/a"
        let estimate = MemoryPreflight.cpuDequantEstimateMiB(units: units.rawValue,
                                                            modelName: variant.modelName)
        let estText = estimate.map { String(format: " · estimate %.0f MB", $0) } ?? ""
        LadderLog.instrument(String(format: "load: %@ %@ · weights %.0f MB · headroom %@ MB"
            + " · footprint %.0f MB%@",
            variant.label, units.rawValue, weightsMB, headText,
            Diagnostics.footprintMB(), estText))
        if !force, let h = headroom, h < weightsMB + 700 {
            throw PipError.model(String(format:
                "memory preflight: app budget %.0f MB < weights %.0f MB + 700 MB",
                h, weightsMB))
        }

        let t = Date()
        unet = try Self.loadModel(named: variant.modelName, units: units.pref,
                                 phase: "unet")
        LadderLog.instrument("\(variant.modelName) loaded on \(units.rawValue) in "
            + String(format: "%.1f", Date().timeIntervalSince(t))
            + String(format: " s · footprint %.0f MB", Diagnostics.footprintMB()))
        // The VAE is fp32: ANE cannot execute it, so ask for CPU+GPU.
        vaeDec = try Self.loadModel(named: "VAEDecoder_sdxl_fp32", units: .cpuAndGPU,
                                    phase: "vae")
        scheduler = try EulerScheduler.bundled()
        try loadConditioning()
        self.variant = variant
        effectiveUnits = units
        let load = Date().timeIntervalSince(t0)
        LadderLog.instrument(String(format: "load done · %.1f s · footprint %.0f MB"
            + " · headroom %@ MB", load, Diagnostics.footprintMB(), headText))
        return load
    }

    /// Drops the loaded models so the next cell starts from a clean footprint:
    /// two UNets at once (the outgoing ANE one plus the one being loaded) is
    /// 5.7 GB of weights on a run whose entire question is memory headroom.
    func release() {
        unet = nil
        vaeDec = nil
        ehs = nil
        txtEmbeds = nil
        timeIds = nil
        scheduler = nil
    }

    /// Loads one model by payload name, honouring the manifest's shipping form.
    ///
    /// `form: "mlmodelc"` (everything served today): the downloaded compiled tree
    /// goes straight to `MLModel(contentsOf:)`. `form: "mlpackage"` (plan B): the
    /// downloaded source package is compiled once on the device into
    /// `Caches/DeviceCompiled/` and that cache is loaded.
    ///
    /// `phase` labels the footprint-watchdog lines around the blocking call.
    static func loadModel(named: String, units: MLComputeUnits,
                          phase: String = "load") throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        let watch = LoadWatchdog.start(model: named, phase: phase)
        defer { watch.stop() }
        do {
            switch PayloadStore.shared.modelSource(named: named) {
            case .compiled(let dir):
                return try MLModel(contentsOf: dir, configuration: cfg)
            case .package(let pkg):
                let compiled = try DeviceCompiler.compiledURL(forModelNamed: named,
                                                              sourcePackage: pkg)
                return try MLModel(contentsOf: compiled, configuration: cfg)
            case nil:
                if let u = Bundle.main.url(forResource: named, withExtension: "mlmodelc") {
                    return try MLModel(contentsOf: u, configuration: cfg)
                }
                throw PipError.model("not installed: \(named) — download the device-v2 payload")
            }
        } catch {
            // A jetsam kill never gets here; anything that *does* arrive has to
            // be visible in telemetry, with the units that were asked for.
            throw PipError.model("\(named) [\(units.rawValue)]: \(error.localizedDescription)")
        }
    }

    /// Baked fixed-prompt conditioning (contract §6.1): row 0 positive, row 1
    /// negative, so the harness only copies them into the batch-2 inputs.
    private func loadConditioning() throws {
        guard let ehsURL = PayloadStore.shared.resourceURL("embeds/encoder_hidden_states.f16"),
              let embURL = PayloadStore.shared.resourceURL("embeds/text_embeds.f16"),
              let idsURL = PayloadStore.shared.resourceURL("embeds/time_ids.f16") else {
            throw PipError.badPayload("embed bins not installed (embeds/*.f16)")
        }
        ehs = try Self.f16Array(url: ehsURL, shape: [2, 77, 2048])
        txtEmbeds = try Self.f16Array(url: embURL, shape: [2, 1280])
        timeIds = try Self.f16Array(url: idsURL, shape: [2, 6])
    }

    // MARK: MLMultiArray helpers

    /// Loads a raw little-endian fp16 bin into an MLMultiArray of `shape`.
    static func f16Array(url: URL, shape: [Int]) throws -> MLMultiArray {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        let count = shape.reduce(1, *)
        guard data.count == count * 2 else {
            throw PipError.badPayload("\(url.lastPathComponent): \(data.count) B, expected \(count * 2)")
        }
        a.dataPointer.bindMemory(to: UInt16.self, capacity: count).withMemoryRebound(
            to: Float16.self, capacity: count) { dst in
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Float16.self)
                for i in 0..<count { dst[i] = src[i] }
            }
        }
        return a
    }

    static func f16Array(shape: [Int], values: [Float16]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        let p = a.dataPointer.bindMemory(to: Float16.self, capacity: a.count)
        guard values.count == a.count else {
            throw PipError.badPayload("f16 fill \(a.count) != \(values.count)")
        }
        for i in 0..<a.count { p[i] = values[i] }
        return a
    }

    static func f32Array(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
        guard values.count == a.count else {
            throw PipError.badPayload("f32 fill \(a.count) != \(values.count)")
        }
        for i in 0..<a.count { p[i] = values[i] }
        return a
    }

    static func f32Copy(_ a: MLMultiArray) throws -> [Float] {
        let n = a.count
        var out = [Float](repeating: 0, count: n)
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

    static func predict(_ model: MLModel,
                        _ arrays: [String: MLMultiArray]) throws -> MLMultiArray {
        var items: [String: MLFeatureValue] = [:]
        for (name, arr) in arrays { items[name] = MLFeatureValue(multiArray: arr) }
        let provider = try MLDictionaryFeatureProvider(dictionary: items)
        let out = try model.prediction(from: provider)
        guard let outName = model.modelDescription.outputDescriptionsByName.keys.first,
              let fv = out.featureValue(for: outName),
              let ma = fv.multiArrayValue else {
            throw PipError.model("no multiarray output")
        }
        return ma
    }

    // MARK: run

    func generate(from image: UIImage, seed: UInt64,
                  steps: Int = Spatial.defaultSteps,
                  onStage: ((String) -> Void)? = nil) throws -> (UIImage, RunStats) {
        guard let unet, let vaeDec, let scheduler, let ehs, let txtEmbeds, let timeIds else {
            throw PipError.model("models not loaded")
        }
        var s = RunStats()
        s.units = effectiveUnits.rawValue
        s.variant = variant.rawValue
        s.steps = steps
        let t0 = Date()
        var peak = currentFootprint()
        Diagnostics.log("generate: seed \(seed) variant \(variant.label) "
                        + "steps \(steps) cfg \(Spatial.guidanceScale) · "
                        + Diagnostics.summary())

        // 1. source -> long edge 768, aspect preserved (Lanczos-3)
        onStage?("Preparing source (long edge \(Spatial.longEdge))…")
        let tPrep = Date()
        let source = try ImageUtils.rgbAtLongEdge(image)
        let contentW = source.width, contentH = source.height
        s.canvas = "\(contentW)x\(contentH) in \(Spatial.canvas)²"

        // 2. canny at that size
        let mask = try CannyEdgeV1.edgeMask(rgb: source.rgb,
                                           width: contentW, height: contentH)

        // 3. centred zero-padded conditioning, both batch rows
        let planes = try CannyEdgeV1.conditionPlanes(mask: mask, width: contentW,
                                                     height: contentH,
                                                     canvas: Spatial.canvas)
        let cond = try MLMultiArray(shape: [2, 3, Spatial.canvas, Spatial.canvas].map { NSNumber(value: $0) },
                                    dataType: .float16)
        let condCount = 3 * Spatial.canvas * Spatial.canvas
        let condPtr = cond.dataPointer.bindMemory(to: Float16.self, capacity: 2 * condCount)
        planes.withUnsafeBufferPointer { src in
            for i in 0..<condCount {
                condPtr[i] = src[i]
                condPtr[condCount + i] = src[i]
            }
        }
        s.encode = Date().timeIntervalSince(tPrep)
        Diagnostics.log("prep: source \(contentW)x\(contentH) → canny "
                        + "\(mask.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }) edge px, "
                        + String(format: "%.2f s", s.encode))

        // 4. init latents (identical in both CFG rows), already × sigma0
        let latentCount = 4 * Spatial.latentSide * Spatial.latentSide
        var gauss = SeededGaussian(seed: seed)
        var latents = gauss.fill(latentCount, scale: scheduler.initNoiseSigma)
        let sample = try MLMultiArray(shape: [2, 4, Spatial.latentSide, Spatial.latentSide].map { NSNumber(value: $0) },
                                      dataType: .float16)
        var timestep = try MLMultiArray(shape: [NSNumber(value: 2)], dataType: .float16)

        func writeSample() {
            let p = sample.dataPointer.bindMemory(to: Float16.self, capacity: 2 * latentCount)
            for i in 0..<latentCount {
                p[i] = Float16(latents[i])
                p[latentCount + i] = Float16(latents[i])
            }
        }
        writeSample()

        // 5. Euler loop, one batch-2 forward per step
        let totalSteps = max(1, min(steps, scheduler.steps))
        onStage?("Diffusion loop (\(totalSteps) steps, CFG \(Int(Spatial.guidanceScale)))…")
        let tLoop = Date()
        var stepPeak: UInt64 = 0
        s.stepMillis.removeAll(keepingCapacity: true)
        for i in 0..<totalSteps {
            let tStep = Date()
            writeSample()
            let tValue = Float16(scheduler.timesteps[i])
            let tPtr = timestep.dataPointer.bindMemory(to: Float16.self, capacity: 2)
            tPtr[0] = tValue
            tPtr[1] = tValue
            let out = try Self.predict(unet, [
                "sample": sample,
                "timestep": timestep,
                "encoder_hidden_states": ehs,
                "text_embeds": txtEmbeds,
                "time_ids": timeIds,
                "controlnet_cond": cond,
            ])
            let noise = try Self.f32Copy(out)
            guard noise.count == 2 * latentCount else {
                throw PipError.model("unet out \(noise.count) != \(2 * latentCount)")
            }
            // eps = neg + 9 * (pos - neg); rows: 0 = positive, 1 = negative
            var eps = [Float](repeating: 0, count: latentCount)
            let g = Spatial.guidanceScale
            for k in 0..<latentCount {
                let pos = noise[k]
                let neg = noise[latentCount + k]
                eps[k] = neg + g * (pos - neg)
            }
            scheduler.step(&latents, eps: eps, index: i)
            s.stepMillis.append(Date().timeIntervalSince(tStep) * 1000)
            stepPeak = max(stepPeak, currentFootprint())
            if i % 5 == 0 || i == totalSteps - 1 {
                let free = Diagnostics.availableMemoryMB()
                    .map { String(format: "%.0f", $0) } ?? "n/a"
                Diagnostics.log(String(format: "step %d/%d %.0f ms · footprint %.0f MB · free %@ MB",
                                       i + 1, totalSteps, s.stepMillis[i],
                                       Double(stepPeak) / 1_048_576.0, free))
            }
        }
        s.loop = Date().timeIntervalSince(tLoop)
        s.peakMemMB = max(s.peakMemMB, Double(stepPeak) / 1_048_576.0)

        // 6. decode (fp32 / cpuAndGPU — the VAE wrapper already divides by 0.13025)
        onStage?("VAE decode (768² fp32)…")
        let tDec = Date()
        let latentsArray = try Self.f32Array(shape: [1, 4, Spatial.latentSide, Spatial.latentSide],
                                             values: latents)
        let decoded = try Self.predict(vaeDec, ["latents": latentsArray])
        let pixels = try Self.f32Copy(decoded)
        s.decode = Date().timeIntervalSince(tDec)

        // 7. crop back to the source aspect and hand back an image
        let cropped = try ImageUtils.uiImage(rgbPlanar: pixels,
                                            canvas: Spatial.canvas,
                                            contentWidth: contentW,
                                            contentHeight: contentH)
        peak = max(peak, currentFootprint())
        s.peakMemMB = max(s.peakMemMB, Double(peak) / 1_048_576.0)
        s.total = Date().timeIntervalSince(t0)
        return (cropped, s)
    }
}
