import CoreML
import CraftRoomCore

/// Build-11 decisive diagnostic: an **`MLComputePlan` probe** per UNet variant.
///
/// Build 10 measured the *load* and found the weights climbing toward fp32 —
/// i.e. the ANE never took the graph, the CPU backend executed everything and
/// ate the memory. A compute plan answers the same question *before* any
/// weight byte is resident: for each variant, build the plan with the same
/// `computeUnits` the cell will use and count operations per preferred
/// device. One line per variant goes to `ladder.log` + telemetry:
///
/// `PLAN variant=split_einsum units=cpuAndNeuralEngine ane=NNN cpu=NNN gpu=NNN unsupported=NNN`
///
/// * `ane > 0`  → the ANE accepts this graph (then only the load footprint
///   decides whether it *keeps* the LUT packed);
/// * `ane = 0`  → the ANE refuses; the ladder falls back to the GPU/fp16
///   cells without risking a jetsam first.
///
/// A failing probe is also a data line (`PLAN failed variant=… error=…`) and
/// never aborts the ladder. Plan construction *is* a compile — for a graph
/// this size it can take minutes — so it runs under the footprint watchdog
/// and once per variant, right before that variant's first cell (the plan
/// line therefore lands in the log before the first load of that variant).
enum PlanProbe {
    private static var probed: Set<String> = []
    private static let lock = NSLock()

    /// Runs the probe once per variant, with the units of the cell about to
    /// run — i.e. exactly the placement question that cell asks.
    static func probeIfNeeded(variant: AttentionVariant, units: ComputeUnitsOption) {
        lock.lock()
        let fresh = !probed.contains(variant.rawValue)
        if fresh { probed.insert(variant.rawValue) }
        lock.unlock()
        guard fresh else { return }
        run(variant: variant, units: units)
    }

    private static func run(variant: AttentionVariant, units: ComputeUnitsOption) {
        guard #available(iOS 18.0, *) else {
            LadderLog.append(ComputePlanLine.failed(variant: variant.rawValue,
                                                    units: units.rawValue,
                                                    error: "MLComputePlan needs iOS 18"))
            return
        }
        LadderLog.instrument("PLAN start variant=\(variant.rawValue)"
            + " units=\(units.rawValue) (plan compile can take minutes)")
        let watch = LoadWatchdog.start(model: "plan:" + variant.modelName, phase: "plan")
        defer { watch.stop() }
        let t0 = Date()
        do {
            guard let url = sourceURL(named: variant.modelName) else {
                throw PipError.model("model not installed: \(variant.modelName)")
            }
            let contents = try MLModelContents(url: url)
            let cfg = MLModelConfiguration()
            cfg.computeUnits = units.pref
            let plan = try MLComputePlan(modelContents: contents, configuration: cfg)
            let structure = plan.modelStructure
            let ane = structure.operatorsByDeviceType[.neuralEngine]?.count ?? 0
            let cpu = structure.operatorsByDeviceType[.cpu]?.count ?? 0
            let gpu = structure.operatorsByDeviceType[.gpu]?.count ?? 0
            let unsupported = structure.unsupportedOperations.count
            LadderLog.append(ComputePlanLine.line(
                variant: variant.rawValue, units: units.rawValue,
                ane: ane, cpu: cpu, gpu: gpu, unsupported: unsupported,
                planSeconds: Date().timeIntervalSince(t0),
                requiredUnits: describe(plan.requiredComputeUnits)))
        } catch {
            LadderLog.append(ComputePlanLine.failed(variant: variant.rawValue,
                                                    units: units.rawValue,
                                                    error: error.localizedDescription))
        }
    }

    /// The plan source: the downloaded `.mlmodelc` (or `.mlpackage`, plan B)
    /// — never the bundled fallback, the probe is about the payload graph.
    private static func sourceURL(named: String) -> URL? {
        switch PayloadStore.shared.modelSource(named: named) {
        case .compiled(let url), .package(let url): return url
        case nil: return nil
        }
    }

    /// `MLComputeUnits` is an int-backed enum; name it for the log.
    private static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .all: return "all"
        case .cpuAndGPU: return "cpuAndGPU"
        case .cpuOnly: return "cpuOnly"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
        @unknown default: return "raw\(units.rawValue)"
        }
    }
}
