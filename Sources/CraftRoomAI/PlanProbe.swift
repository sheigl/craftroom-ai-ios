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

    /// Plan construction is a full compile (minutes for a graph this size),
    /// so the async `MLComputePlan.load` runs on a detached task while this
    /// (background) thread waits on a semaphore — same shape as the 15-min
    /// model-load timeout. A timed-out probe logs its line and lets the task
    /// finish on its own; the watchdog keeps measuring it.
    private static func run(variant: AttentionVariant, units: ComputeUnitsOption) {
        guard #available(iOS 18.0, *) else {
            LadderLog.append(ComputePlanLine.failed(variant: variant.rawValue,
                                                    units: units.rawValue,
                                                    error: "MLComputePlan needs iOS 18"))
            return
        }
        LadderLog.instrument("PLAN start variant=\(variant.rawValue)"
            + " units=\(units.rawValue) (plan compile can take minutes)")
        guard let url = sourceURL(named: variant.modelName) else {
            LadderLog.append(ComputePlanLine.failed(variant: variant.rawValue,
                units: units.rawValue,
                error: "model not installed: \(variant.modelName)"))
            return
        }
        let watch = LoadWatchdog.start(model: "plan:" + variant.modelName, phase: "plan")
        let t0 = Date()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            defer { done.signal() }
            do {
                let cfg = MLModelConfiguration()
                cfg.computeUnits = units.pref
                let plan = try await MLComputePlan.load(contentsOf: url, configuration: cfg)
                var counts = (ane: 0, cpu: 0, gpu: 0, unsupported: 0)
                switch plan.modelStructure {
                case .program(let program):
                    for function in program.functions.values {
                        count(block: function.block, in: plan, depth: 0, into: &counts)
                    }
                case .neuralNetwork, .pipeline:
                    throw PipError.model("structure not mlprogram")
                case .unsupported:
                    throw PipError.model("structure unsupported")
                @unknown default:
                    throw PipError.model("structure unknown")
                }
                LadderLog.append(ComputePlanLine.line(
                    variant: variant.rawValue, units: units.rawValue,
                    ane: counts.ane, cpu: counts.cpu, gpu: counts.gpu,
                    unsupported: counts.unsupported,
                    planSeconds: Date().timeIntervalSince(t0),
                    requiredUnits: requiredUnitsName(ane: counts.ane, cpu: counts.cpu,
                                                     gpu: counts.gpu)))
            } catch {
                LadderLog.append(ComputePlanLine.failed(variant: variant.rawValue,
                                                        units: units.rawValue,
                                                        error: error.localizedDescription))
            }
            watch.stop()
        }
        if done.wait(timeout: .now() + .seconds(Self.planTimeoutSeconds)) == .timedOut {
            LadderLog.append(ComputePlanLine.failed(variant: variant.rawValue,
                units: units.rawValue,
                error: "plan-timeout-\(Self.planTimeoutSeconds)s"))
            // The abandoned compile keeps running; keep the watchdog on it.
            _ = watch
        }
    }

    /// Seconds a single `MLComputePlan.load` may take before we log a timeout
    /// (the compile is as heavy as the load it predicts: 2× the load budget).
    static let planTimeoutSeconds = 1800

    /// Ops per preferred device over one program block, recursing into the
    /// nested blocks of control-flow operations (depth-limited; the UNet has
    /// none, but a silent undercount would be worse than recursion).
    @available(iOS 18.0, *)
    private static func count(block: MLModelStructure.Program.Block,
                              in plan: MLComputePlan, depth: Int,
                              into counts: inout (ane: Int, cpu: Int, gpu: Int, unsupported: Int)) {
        for op in block.operations {
            if let usage = plan.deviceUsage(for: op) {
                switch usage.preferred {
                case .neuralEngine: counts.ane += 1
                case .gpu: counts.gpu += 1
                case .cpu: counts.cpu += 1
                @unknown default: counts.cpu += 1
                }
            } else {
                counts.unsupported += 1
            }
            if depth < 8 {
                for inner in op.blocks { count(block: inner, in: plan, depth: depth + 1, into: &counts) }
            }
        }
    }

    /// Canonical name of the unit set the plan's placements demand: the ANE
    /// taking ops is the whole question, so surface it in one token.
    private static func requiredUnitsName(ane: Int, cpu: Int, gpu: Int) -> String {
        switch (ane > 0, gpu > 0) {
        case (true, true): return "all"
        case (true, false): return "cpuAndNeuralEngine"
        case (false, true): return "cpuAndGPU"
        case (false, false): return "cpuOnly"
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
}
