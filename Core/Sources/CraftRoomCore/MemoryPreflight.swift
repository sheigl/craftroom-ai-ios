import Foundation

/// Estimated-footprint preflight for ladder cells (build 10 rules, revised to
/// **v2** for build 11 after the build-10 telemetry).
///
/// Build-10 measurement (iPad16,8, 2026-11-07): the load footprint of the
/// 6-bit SDPA package on `cpuAndNeuralEngine` climbed 0.5 → 10.25 GB in 19 s
/// and was jetsam-killed — the weights were being **de-palettized toward
/// fp32**, not fp16: the model has 3.82 B params (palettized 3,816,113,664),
/// so fp16 resident would plateau at 7,283 MiB and never reach 10 GB, while
/// fp32 (15.3 GB = 14,567 MiB) is exactly where the climb was heading.
/// `cpuOnly` in build 9 died the same way. Conclusions baked here:
///
///  * **cpuOnly + any UNet variant** (6-bit *or* fp16) → estimate the fp32
///    widening, ≥ 14.5 GiB (`cpuUnpackedFP32MiB`): the CPU backend does not
///    stop at fp16. With the 1,500 MiB working-set margin this exceeds the
///    measured 12,273 MiB budget on this iPad → `AUTO-SKIP` before loading.
///  * **fp16 variant on GPU/ANE** → estimate 7,250 MiB (`fp16WeightsMiB`,
///    3.82 B × 2 B) + 1,500 margin = 8,750 MiB: fits the budget, so attempt.
///  * **6-bit packed on ANE/GPU** → the *packed* estimate is 3,000 MiB, but
///    build 10 showed the backends may widen it anyway. Never refuse these
///    cells: they are the measurement (watchdog records the climb or the
///    plateau); refusing would hide exactly the question being asked.
///
/// `force: true` on a cell overrides every refusal, mirroring the app's
/// "load even if impossible" toggle.
public enum MemoryPreflight {
    /// Resident fp16 weights of the *unpalettized* UNet+ControlNet package
    /// (3.82 B params × 2 B ≈ 7,283 MiB on disk; contract
    /// `fp16_bytes_unpalettized` 7,641,885,480 B = 7,287 MiB).
    public static let fp16WeightsMiB: Double = 7_250

    /// Build-10 name kept for the contract figure (same number, documented
    /// history): the fp16 de-palettization estimate that build 10 baked for
    /// cpuOnly before the watchdog proved the widening went to **fp32**.
    public static var palettizedFP16WeightsMiB: Double { fp16WeightsMiB }

    /// What a `cpuOnly` UNet load actually costs: the CPU backend widens the
    /// weights to fp32 (3.82 B × 4 B ≈ 14,567 MiB — the build-10 climb
    /// direction, and why cpuOnly died in builds 9 and 10). ≥ 14.5 GiB.
    public static let cpuUnpackedFP32MiB: Double = 14_600

    /// Packed 6-bit footprint on ANE/GPU — *informational*: those cells are
    /// never refused (the whole point of the ladder is whether the backend
    /// keeps the LUT compressed).
    public static let packed6BitMiB: Double = 3_000

    /// Extra headroom demanded on top of the estimate before a cell is allowed
    /// to run (activations + fp32 VAE decode + harness buffers).
    public static let workingSetMarginMiB: Double = 1_500

    public enum Outcome: Equatable {
        /// run the cell
        case attempt
        /// refuse the cell; `reason` is the machine-readable token after
        /// `reason=` on the `AUTO-SKIP` line
        case skip(reason: String)

        public var isSkip: Bool {
            if case .skip = self { return true }
            return false
        }
    }

    /// Machine-readable reason tokens for the `AUTO-SKIP` line.
    public static let cpuDequantReason = "cpu-backend-dequant-estimate"
    public static let fp16WeightsReason = "fp16-weights-estimate"

    /// One cell's weight estimate: `miB` for the log line, `refuses` whether
    /// a tight headroom may AUTO-SKIP it (6-bit ANE/GPU cells carry an
    /// estimate but never refuse).
    public struct Estimate: Equatable {
        public let miB: Double
        public let refuses: Bool
        public let reason: String
    }

    /// Estimate for one ladder cell. The UNet is identified by the contract
    /// model-name stem `canny1200`; everything else (VAEs, embeds) is nil.
    public static func estimate(units: String, modelName: String) -> Estimate? {
        guard modelName.contains("canny1200") else { return nil }
        let packed = modelName.contains("6bit")
        if units == "cpuOnly" {
            // Any UNet on the CPU backend widens to fp32 (build-9/10 evidence:
            // cpuOnly died the same way as ANE, mid-climb toward 15.3 GB).
            return Estimate(miB: cpuUnpackedFP32MiB, refuses: true,
                            reason: cpuDequantReason)
        }
        if !packed {
            // The fp16 package on GPU/ANE: 7,250 + 1,500 = 8,750 MiB — this
            // iPad's 12,273 MiB budget fits, so normally attempt; refuse only
            // if something already ate most of the headroom.
            return Estimate(miB: fp16WeightsMiB, refuses: true,
                            reason: fp16WeightsReason)
        }
        // 6-bit packed on ANE/GPU: informational, never refuse (the ladder is
        // measuring whether the backend keeps it packed).
        return Estimate(miB: packed6BitMiB, refuses: false, reason: cpuDequantReason)
    }

    /// Decision for one cell. `headroomMB` is `os_proc_available_memory()`
    /// (nil on failure → we attempt, because an unmeasurable budget must not
    /// silently drop data).
    public static func decide(headroomMB: Double?, estimateMB: Double?,
                              marginMB: Double = workingSetMarginMiB,
                              force: Bool = false,
                              reason: String = cpuDequantReason) -> Outcome {
        guard !force, let estimateMB else { return .attempt }
        guard let headroomMB else { return .attempt }
        return headroomMB < estimateMB + marginMB
            ? .skip(reason: reason)
            : .attempt
    }

    /// One-shot convenience used by the harness: estimate + decide in one
    /// call. Informational estimates (`refuses == false`) always attempt.
    public static func decideCell(units: String, modelName: String,
                                  headroomMB: Double?, force: Bool = false) -> Outcome {
        guard let est = estimate(units: units, modelName: modelName), est.refuses else {
            return .attempt
        }
        return decide(headroomMB: headroomMB, estimateMB: est.miB,
                      force: force, reason: est.reason)
    }

    /// `needs 16100 MB of 12273 MB` style detail for the log line.
    public static func detail(headroomMB: Double?, estimateMB: Double,
                              marginMB: Double = workingSetMarginMiB) -> String {
        let need = String(format: "%.0f", estimateMB + marginMB)
        let have = headroomMB.map { String(format: "%.0f", $0) } ?? "n/a"
        return "needs \(need) MB of \(have) MB (estimate \(String(format: "%.0f", estimateMB))"
            + " + margin \(String(format: "%.0f", marginMB)))"
    }
}
