import UIKit
import CraftRoomCore

/// Owns the loaded models across runs. The UNet must be reloaded when the
/// compute-unit set or the attention variant changes; the VAE never does.
///
/// Moved here from `ContentView` for v0.6, unchanged except for the typed
/// progress callback the product flow needs; the ladder still calls `run`
/// exactly as before.
final class Engine {
    private var inference: Inference?
    private var loadedUnits: ComputeUnitsOption?
    private var loadedVariant: AttentionVariant?
    private(set) var lastLoad: Double = 0

    func run(units: ComputeUnitsOption, variant: AttentionVariant, photo: UIImage,
             seed: UInt64, forceLoad: Bool,
             onStage: @escaping (String) -> Void,
             steps: Int = Spatial.defaultSteps,
             onProgress: ((Stage, Double) -> Void)? = nil) throws -> (UIImage, RunStats) {
        if inference == nil || loadedUnits != units || loadedVariant != variant {
            onStage("Loading \(variant.label) on \(units.label)…")
            onProgress?(.preparing, 0.02)
            // Drop the outgoing models BEFORE loading: two UNets at once is
            // 5.7 GB on a run whose whole question is headroom (build 10).
            inference?.release()
            inference = nil
            loadedUnits = nil
            loadedVariant = nil
            let inf = Inference()
            lastLoad = try inf.loadModels(units: units, variant: variant, force: forceLoad)
            inference = inf
            loadedUnits = units
            loadedVariant = variant
        }
        guard let inference else { throw PipError.model("engine not ready") }
        var (img, stats) = try inference.generate(from: photo, seed: seed,
                                                 steps: steps, onStage: onStage,
                                                 onProgress: onProgress)
        stats.modelLoad = lastLoad
        stats.units = inference.effectiveUnits.rawValue
        return (img, stats)
    }
}

/// The on-device backend (plan T3.2): an adapter over the existing Core ML
/// path. Nothing about the inference, the payload, the ladder or the cursor
/// changes — this type only translates `GenerationInput` into the existing
/// `Engine.run` call and `RunStats` back into a `PageResult`, and forwards
/// progress in the same `Stage` vocabulary the remote engine uses.
final class OnDeviceEngine: GenerationEngine {
    let id: EngineID = .onDevice

    private let engine: Engine

    init(engine: Engine) {
        self.engine = engine
    }

    /// Product defaults for the on-device path: `all` compute units (ANE + GPU),
    /// the attention variant selected in the payload UI, 30 steps and CFG 9 —
    /// i.e. exactly what a normal Generate press has always used.
    private var variant: AttentionVariant {
        AttentionVariant(rawValue: PayloadStore.shared.variant) ?? .sdpa
    }

    func health() async throws -> EngineHealth {
        let store = PayloadStore.shared
        switch store.state {
        case .ready:
            let variant = self.variant
            let bytes = store.variantWeightBytes
            let gb = Double(bytes) / 1_073_741_824
            return EngineHealth(
                ok: true,
                engine: .onDevice,
                summary: String(format: "Models installed · %@ attention · %.1f GB",
                                variant.label, gb),
                detail: "Runs entirely on this iPad. No Wi-Fi needed.",
                modelID: variant.modelName,
                checkedAt: Date())
        case .missing(let totalMB):
            return EngineHealth(
                ok: false,
                engine: .onDevice,
                summary: "Models not downloaded",
                detail: String(format: "Download %.1f GB in Settings → Developer, "
                               + "or switch to Local server.",
                               Double(totalMB) / 1024),
                checkedAt: Date())
        case .downloading(let fraction, let doneMB, let totalMB):
            return EngineHealth(
                ok: false,
                engine: .onDevice,
                summary: String(format: "Downloading %.0f %% (%lld / %lld MB)",
                                fraction * 100, doneMB, totalMB),
                checkedAt: Date())
        case .failed(let message):
            return EngineHealth(
                ok: false,
                engine: .onDevice,
                summary: "Model download failed",
                detail: message,
                checkedAt: Date())
        case .checking:
            return EngineHealth(ok: false, engine: .onDevice,
                                summary: "Checking installed models…",
                                checkedAt: Date())
        }
    }

    func generate(_ input: GenerationInput,
                  progress: @escaping (Stage, Double) -> Void) async throws -> PageResult {
        guard case .ready = PayloadStore.shared.state else {
            throw EngineError.payloadMissing
        }
        guard let image = UIImage(data: input.photo) else {
            throw EngineError.invalidPhoto("the picked photo could not be decoded")
        }
        let variant = self.variant
        let seed = input.seed ?? 42
        let steps = Spatial.defaultSteps
        let units: ComputeUnitsOption = .all
        let started = Date()

        progress(.preparing, 0.02)
        // The pipeline is synchronous and CPU/GPU/ANE bound: run it off the main
        // thread exactly like the ladder does, and forward progress hops back.
        let outcome: (UIImage, RunStats) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(UIImage, RunStats), Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [engine] in
                do {
                    let result = try engine.run(
                        units: units,
                        variant: variant,
                        photo: image,
                        seed: seed,
                        forceLoad: true,
                        onStage: { message in
                            Diagnostics.log("stage: \(message)")
                        },
                        steps: steps,
                        onProgress: { stage, fraction in
                            progress(stage, fraction)
                        })
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let page = outcome.0
        let stats = outcome.1
        guard let png = page.pngData() else {
            throw EngineError.badResponse("the page could not be encoded as PNG")
        }
        let width = Int(page.size.width.rounded())
        let height = Int(page.size.height.rounded())
        let metadata = PageMetadata(
            engine: .onDevice,
            model: variant.modelName,
            seed: Int(seed),
            steps: steps,
            cfg: Double(Spatial.guidanceScale),
            width: width,
            height: height,
            recipe: "canny_edge_v1",
            timings: [
                "model_load_s": stats.modelLoad,
                "prepare_s": stats.prep + stats.encode,
                "loop_s": stats.loop,
                "decode_s": stats.decode,
                "total_s": stats.total,
            ])
        progress(.done, 1)
        return PageResult(png: png, width: width, height: height,
                          metadata: metadata,
                          elapsed: Date().timeIntervalSince(started))
    }
}
