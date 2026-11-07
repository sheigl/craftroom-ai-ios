import Foundation

/// Canonical compute-unit tokens for ladder cells (build 11).
///
/// Pure parsing so the app's `ComputeUnitsOption` mapping and the unit tests
/// share one rule. `auto.json` / `auto_default.json` cells and the launch-arg
/// ladder spell units several ways (`cpuOnly`, `cpu_only`, `ane`, `gpu`, …);
/// build 11 adds the GPU sets the fp16 fallback ladder needs.
public enum LadderUnits: String, CaseIterable, Equatable {
    case all
    case cpuAndNeuralEngine
    case cpuAndGPU
    case cpuOnly

    /// Canonical form for one cell's `units` string. Unknown or absent →
    /// `all` (Core ML's own scheduling), which is what build 10 defaulted to.
    public static func canonical(_ raw: String?) -> LadderUnits {
        strict(raw) ?? .all
    }

    /// Strict form for the unattended matrix files: an unknown or empty token
    /// must fail the file loudly — a cell silently relabelled to `all` would
    /// poison the results table.
    public static func strict(_ raw: String?) -> LadderUnits? {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: ""),
              !key.isEmpty else { return nil }
        switch key {
        case "cpuonly", "cpu":                            return .cpuOnly
        case "cpuandneuralengine", "ane", "ne", "neuralengine":
            return .cpuAndNeuralEngine
        case "cpuandgpu", "gpu":                          return .cpuAndGPU
        case "all":                                       return .all
        default:                                          return nil
        }
    }
}

/// The exact `PLAN` telemetry line an `MLComputePlan` probe produces (see
/// the app's `PlanProbe`). One line per UNet variant answers the decisive
/// question — *will the ANE take this graph?* — without loading a single
/// weight byte, so a wrong answer costs no jetsam.
public enum ComputePlanLine {
    /// `PLAN variant=split_einsum units=cpuAndNeuralEngine ane=41203 cpu=12 gpu=0 unsupported=0`
    /// plus ` · ` separated extras (plan seconds, required units).
    public static func line(variant: String, units: String,
                            ane: Int, cpu: Int, gpu: Int, unsupported: Int,
                            planSeconds: Double? = nil,
                            requiredUnits: String? = nil) -> String {
        var s = "PLAN variant=\(variant) units=\(units) ane=\(ane) cpu=\(cpu)"
            + " gpu=\(gpu) unsupported=\(unsupported)"
        if let planSeconds {
            s += String(format: " · plan_s=%.1f", planSeconds)
        }
        if let requiredUnits {
            s += " · required=\(requiredUnits)"
        }
        return s
    }

    /// The never-abort variant: a failed probe is a data line too.
    public static func failed(variant: String, units: String, error: String) -> String {
        "PLAN failed variant=\(variant) units=\(units) error=\(error)"
    }
}
