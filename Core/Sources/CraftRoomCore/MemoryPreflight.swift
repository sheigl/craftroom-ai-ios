import Foundation

/// Estimated-footprint preflight for the CPU-backend cells (build 10).
///
/// Evidence it comes from (iPad16,8, build 9, 2026-11-06 19:44): the first
/// cell was `cpuOnly/sdpa/1`, the load line printed
/// `load: SDPA cpuOnly · weights 6782 MB · headroom 12273 MB`, and the process
/// died *inside* `MLModel(contentsOf:)` — no throw, no `ERROR` line, no
/// `… loaded in X s`. The leading explanation (hypothesis A) is that the CPU
/// backend de-palettizes the 6-bit LUT weights into a resident fp16 copy, so
/// the load costs the *unpalettized* size instead of the shipped one:
///
/// `sdxl/teacher/device_v2_io_contract.json`
///   palettization.palettized_params    = 3,816,113,664 params
///   × 2 B (fp16)                       = 7,632,227,328 B = 7,277 MiB
///   package.fp16_bytes_unpalettized    = 7,641,885,480 B = 7,287 MiB
///
/// so a 2.87 GB download is really a ~7.1 GiB load. Baked as the round
/// **7,250 MiB** (just under both figures: the estimate must not be inflated
/// by zip/metadata padding, and the shipped `.mlmodelc` is what is measured).
/// A cell is refused when the app's remaining headroom cannot hold that plus a
/// **1,500 MiB** working set (activations, the fp32 VAE, the harness arrays) —
/// refusing is a measurement too, so it is logged as `AUTO-SKIP`, not hidden.
///
/// ANE/GPU cells are never refused here: palettized weights stay compressed for
/// those backends, which is exactly the thing the ladder is measuring. And
/// `force: true` on a cell overrides the estimate (the owner can always force
/// the experiment), mirroring the app's "load even if impossible" toggle.
public enum MemoryPreflight {
    /// Dequantized fp16 weight footprint of a 6-bit palettized UNet+ControlNet.
    public static let palettizedFP16WeightsMiB: Double = 7_250

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

    /// The machine-readable reason token used on the `AUTO-SKIP` line.
    public static let cpuDequantReason = "cpu-backend-dequant-estimate"

    /// Estimate (MiB) of what loading this cell's UNet costs the CPU backend,
    /// nil when the cell is not exposed to the de-palettize path.
    ///
    /// Only `cpuOnly` with a **palettized** model qualifies: the fp16 (6-bit
    /// free) package is already fp16 on disk, and ANE/GPU keep the LUT layout.
    public static func cpuDequantEstimateMiB(units: String, modelName: String) -> Double? {
        guard units == "cpuOnly" else { return nil }
        // "…_6bit" is the palettized export in both attention variants; the
        // unpalettized package name has no such suffix.
        guard modelName.contains("6bit") else { return nil }
        return palettizedFP16WeightsMiB
    }

    /// Decision for one cell. `headroomMB` is `os_proc_available_memory()`
    /// (nil on failure → we attempt, because an unmeasurable budget must not
    /// silently drop data).
    public static func decide(headroomMB: Double?, estimateMB: Double?,
                              marginMB: Double = workingSetMarginMiB,
                              force: Bool = false) -> Outcome {
        guard !force, let estimateMB else { return .attempt }
        guard let headroomMB else { return .attempt }
        return headroomMB < estimateMB + marginMB
            ? .skip(reason: cpuDequantReason)
            : .attempt
    }

    /// One-shot convenience used by the harness: estimate + decide in one call.
    public static func decideCell(units: String, modelName: String,
                                  headroomMB: Double?, force: Bool = false) -> Outcome {
        decide(headroomMB: headroomMB,
               estimateMB: cpuDequantEstimateMiB(units: units, modelName: modelName),
               force: force)
    }

    /// `needs 8750 MB of 12273 MB` style detail for the log line.
    public static func detail(headroomMB: Double?, estimateMB: Double,
                              marginMB: Double = workingSetMarginMiB) -> String {
        let need = String(format: "%.0f", estimateMB + marginMB)
        let have = headroomMB.map { String(format: "%.0f", $0) } ?? "n/a"
        return "needs \(need) MB of \(have) MB (estimate \(String(format: "%.0f", estimateMB))"
            + " + margin \(String(format: "%.0f", marginMB)))"
    }
}
