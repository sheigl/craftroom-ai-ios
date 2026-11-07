import Foundation
import UIKit
import CraftRoomCore

/// The T5 measurement ladder (builds 9–11): the matrix of compute-unit ×
/// attention × steps cells, its crash cursor, the selftest, the watchdog lines
/// and the run-once marker — unchanged in behaviour, with **one deliberate
/// difference** for v0.6: nothing starts it implicitly. The bundled
/// `auto_default.json` runs only when the owner taps "Run ladder" in
/// Settings → Developer. A `--auto` launch argument (the USB/pdm3 path) still
/// runs its single cell, because that invocation is itself explicit.
///
/// The product flow does not depend on this file; an idle ladder costs nothing.
@MainActor
final class LadderController: ObservableObject {
    // MARK: cell model

    struct AutoCell {
        var units: ComputeUnitsOption
        var variant: AttentionVariant
        var steps: Int
        var seed: UInt64
        /// Overrides the estimated-skip preflight (auto.json `"force": true`).
        var force: Bool = false

        var label: String { "\(units.rawValue)/\(variant.rawValue)/\(steps)" }
    }

    enum AutoSource: String { case launchArgs, documents, bundled }

    // MARK: state

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Ladder idle"
    @Published private(set) var logText = ""
    /// The ladder paints the screen black and holds it awake while it measures.
    @Published private(set) var dimmed = false
    @Published private(set) var lastLine = ""
    /// Default ON, exactly as build 11 shipped: a kill still leaves the
    /// budget-vs-weights line in the log, which is the measurement.
    @Published var forceLoad = true

    private let engine: Engine
    private var cursor: LadderCursor?
    private var autoStarted = false
    private var waitLogged = false
    private var parseFailLogged = false
    /// Set only by `start()` (the owner's tap) — never by `onAppear`.
    private var requested = false

    init(engine: Engine) {
        self.engine = engine
    }

    /// The owner's explicit "Run ladder" tap.
    func start() {
        requested = true
        runIfRequested()
    }

    /// Called on launch and whenever the payload finishes downloading: runs a
    /// ladder only if one was requested (or a `--auto` launch argument exists).
    func runIfRequested() {
        guard requested || launchArgCell() != nil else { return }
        guard !autoStarted else { return }
        maybeStart()
    }

    func refreshLog() {
        logText = Diagnostics.tail(120)
    }

    // MARK: ladder sources

    private nonisolated static func units(from s: String?) -> ComputeUnitsOption? {
        switch LadderUnits.strict(s) {
        case .cpuOnly: return .cpuOnly
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        case .all: return .all
        case nil: return nil   // an unknown unit would mislabel the matrix — fail the file
        }
    }

    private nonisolated static func variant(from s: String?) -> AttentionVariant? {
        AttentionVariant(rawValue: s ?? "")
    }

    private nonisolated static func autoJSONURL() -> URL? {
        PayloadStore.documentsURL?.appendingPathComponent("auto.json")
    }

    /// Written after a BUNDLED ladder finishes so a relaunch never repeats the
    /// hours-long matrix (the pushed-file equivalent is the rename to
    /// auto.done.json).
    private nonisolated static func autoDefaultDoneURL() -> URL? { LadderStore.defaultDoneURL }

    /// `{"cells":[{units, model, steps, seed, force}, …]}` — same protocol for
    /// the pushed auto.json and the bundled auto_default.json.
    private nonisolated static func parseCells(_ data: Data) -> [AutoCell]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["cells"] as? [[String: Any]], !raw.isEmpty else { return nil }
        var cells: [AutoCell] = []
        for c in raw {
            guard let units = Self.units(from: c["units"] as? String),
                  let variant = Self.variant(from: c["model"] as? String) else { return nil }
            cells.append(AutoCell(units: units, variant: variant,
                                  steps: max(1, min(30, (c["steps"] as? NSNumber)?.intValue
                                                    ?? (c["maxSteps"] as? NSNumber)?.intValue ?? 30)),
                                  seed: (c["seed"] as? NSNumber)?.uint64Value ?? 42,
                                  force: (c["force"] as? NSNumber)?.boolValue ?? false))
        }
        return cells
    }

    /// Launch args → Documents/auto.json (still wins) → bundled auto_default.json
    /// (skipped once auto_default.done marks a finished run).
    private func autoLadder() -> (cells: [AutoCell], source: AutoSource)? {
        if let single = launchArgCell() { return ([single], .launchArgs) }
        if let url = Self.autoJSONURL(), let data = try? Data(contentsOf: url) {
            if let cells = Self.parseCells(data) { return (cells, .documents) }
            if !parseFailLogged {
                parseFailLogged = true
                LadderLog.append("ERROR auto: auto.json parse failed — every cell needs a"
                    + " known units (all|cpuAndNeuralEngine|cpuAndGPU|cpuOnly) and model"
                    + " (sdpa|split_einsum|fp16); bundled ladder NOT started")
            }
            return nil
        }
        if let done = Self.autoDefaultDoneURL(),
           FileManager.default.fileExists(atPath: done.path) { return nil }
        if let url = Bundle.main.url(forResource: "auto_default", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cells = Self.parseCells(data) { return (cells, .bundled) }
        return nil
    }

    private func launchArgCell() -> AutoCell? {
        let a = CommandLine.arguments
        guard a.contains("--auto") else { return nil }
        func val(_ key: String) -> String? {
            guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
            return a[i + 1]
        }
        return AutoCell(units: Self.units(from: val("--units")) ?? .all,
                        variant: Self.variant(from: val("--model")) ?? .sdpa,
                        steps: max(1, min(30, Int(val("--steps") ?? "30") ?? 30)),
                        seed: UInt64(val("--seed") ?? "42") ?? 42,
                        force: a.contains("--force"))
    }

    // MARK: start

    private func maybeStart() {
        guard !autoStarted, let auto = autoLadder() else { return }
        let cells = auto.cells
        guard case .ready = PayloadStore.shared.state else {
            if !waitLogged {
                waitLogged = true
                LadderLog.instrument("auto: waiting for payload install "
                                     + "(base \(PayloadStore.shared.baseURL)) — tap "
                                     + "Download models in Settings → Developer")
            }
            return
        }
        autoStarted = true
        guard let url = Bundle.main.url(forResource: "test_photo", withExtension: "jpg"),
              let img = UIImage(contentsOfFile: url.path) else {
            LadderLog.append("ERROR auto: bundled test_photo.jpg missing")
            return
        }

        // ---- crash cursor: the anti-crash-loop (build 10) ------------------
        var cursor: LadderCursor?
        if auto.source != .launchArgs {
            let labels = cells.map(\.label)
            let id = LadderCursor.ladderID(for: labels)
            var c = LadderStore.load(matching: id) ?? LadderCursor(ladderID: id, labels: labels)
            let carried = c.cells.contains { $0.attempts > 0 || $0.state != .pending }
            for r in c.recoverAfterRestart() {
                LadderLog.append("AUTO-FAIL cell=\(r.label) reason=process-restart"
                    + " (attempt \(r.attempts))"
                    + (r.willRetry ? " → one retry left" : " → giving up, advancing"))
            }
            if carried {
                LadderLog.append("auto: resuming existing cursor (\(c.summary()))")
            }
            if c.isComplete {
                LadderLog.append("auto: cursor exhausted (\(c.summary())) — not restarting"
                    + " the ladder [\(auto.source.rawValue)] \(cells.count) cell(s)")
                if auto.source == .bundled {
                    LadderStore.markDefaultDone("cursor exhausted: \(c.summary())")
                }
                LadderStore.save(c)
                Telemetry.send(Telemetry.deliverySummary)
                status = "Ladder already finished — see ladder.log."
                refreshLog()
                return
            }
            cursor = c
            LadderStore.save(c)
        }
        self.cursor = cursor

        dimmed = true
        isRunning = true
        let startLine = "auto: \(cells.count) cell(s) [\(auto.source.rawValue)] — "
            + cells.map(\.label).joined(separator: " · ")
        LadderLog.append(startLine)
        lastLine = startLine
        run(photo: img, cells: cells, source: auto.source, cursor: cursor)
    }

    // MARK: the pass

    /// One pass over the ladder. A settled cell is skipped, a cell certain to
    /// jetsam is refused, the cursor is written before the load, and a dead cell
    /// is a data point rather than the end of the matrix. See builds 9–11 in
    /// `HANDOFF.md`.
    private func run(photo: UIImage, cells: [AutoCell], source: AutoSource,
                     cursor initialCursor: LadderCursor?) {
        var cursor = initialCursor
        let forceAll = forceLoad
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }

            // The plan, in durable order: a reader can see the intended matrix
            // even when the first cell kills the process.
            for cell0 in cells { LadderLog.append("CELL \(cell0.label)") }
            LadderLog.instrument("selftest: VAEDecoder_sdxl_fp32 before cell 1")
            SelfTest.runVAEOnce()

            var didReset = false
            var consecutiveFailures = 0
            var stoppedEarly = false
            for (idx, cell) in cells.enumerated() {
                var lastStage = "start"
                if let st = cursor?.state(idx), st != .pending {
                    LadderLog.append("RESUME-SKIP cell=\(cell.label) reason=already-\(st.rawValue)")
                    continue
                }
                if !PayloadStore.shared.isReady(variant: cell.variant.rawValue) {
                    cursor?.skip(idx)
                    Self.persist(cursor)
                    LadderLog.append("AUTO-SKIP cell=\(cell.label) reason=payload-missing"
                        + " · \(cell.variant.modelName) not downloaded — pick the"
                        + " \(cell.variant.rawValue) variant in the payload UI first")
                    continue
                }
                let headroom = Diagnostics.availableMemoryMB()
                if let est = MemoryPreflight.estimate(units: cell.units.rawValue,
                                                      modelName: cell.variant.modelName),
                   case .skip(let reason) = MemoryPreflight.decideCell(
                       units: cell.units.rawValue, modelName: cell.variant.modelName,
                       headroomMB: headroom, force: cell.force || forceAll) {
                    cursor?.skip(idx)
                    Self.persist(cursor)
                    LadderLog.append(String(format:
                        "AUTO-SKIP cell=%@ reason=%@ · %@ · footprint %.0f MB",
                        cell.label, reason,
                        MemoryPreflight.detail(headroomMB: headroom, estimateMB: est.miB),
                        Diagnostics.footprintMB()))
                    continue
                }
                let attempt = cursor?.begin(idx) ?? 1
                Self.persist(cursor)
                let free = Diagnostics.availableMemoryMB().map { String(format: "%.0f", $0) }
                    ?? "n/a"
                LadderLog.append(String(format:
                    "START cell=%@ attempt=%d index=%d/%d · footprint %.0f MB · headroom %@ MB",
                    cell.label, attempt, idx + 1, cells.count,
                    Diagnostics.footprintMB(), free))
                PlanProbe.probeIfNeeded(variant: cell.variant, units: cell.units)
                if !didReset {
                    Diagnostics.reset("run on \(cell.label) seed \(cell.seed)"
                        + " photo \(Int(photo.size.width))x\(Int(photo.size.height))")
                    didReset = true
                } else {
                    Diagnostics.log("=== cell \(idx + 1)/\(cells.count): \(cell.label)"
                        + " attempt \(attempt)")
                }
                await MainActor.run {
                    self.status = "Starting \(cell.label)…"
                }
                do {
                    let stageSink: (String) -> Void = { msg in
                        lastStage = msg
                        Diagnostics.log("stage: " + msg)
                        Task { @MainActor [weak self] in self?.status = msg }
                    }
                    let (img, s) = try self.engine.run(units: cell.units,
                                                       variant: cell.variant,
                                                       photo: photo,
                                                       seed: cell.seed,
                                                       forceLoad: forceAll,
                                                       onStage: stageSink,
                                                       steps: cell.steps)
                    let saved = Self.saveRender(img, cell: cell, seed: cell.seed)
                    cursor?.settle(idx, .done)
                    Self.persist(cursor)
                    consecutiveFailures = 0
                    let line = Self.autoResult(s, cell)
                    LadderLog.append(line)
                    if let saved { LadderLog.instrument("render saved \(saved)") }
                    await MainActor.run {
                        self.status = "Done."
                        self.lastLine = line
                        self.refreshLog()
                    }
                } catch {
                    let msg = error.localizedDescription
                    let failedAt = lastStage
                    let reason = msg.localizedCaseInsensitiveContains("load-timeout")
                        ? "load-timeout" : "error"
                    cursor?.settle(idx, .failed)
                    Self.persist(cursor)
                    consecutiveFailures += 1
                    Diagnostics.log("ERROR at \(failedAt): \(msg)")
                    let line = "FAILED cell=\(cell.label) attempt=\(attempt)"
                        + " reason=\(reason) at \(failedAt): \(msg)"
                    LadderLog.append(line)
                    await MainActor.run {
                        self.status = "\(failedAt) failed: \(msg)"
                        self.lastLine = line
                        self.refreshLog()
                    }
                    if consecutiveFailures >= Self.consecutiveFailureStop {
                        LadderLog.append("auto: \(consecutiveFailures) consecutive failures"
                            + " — stopping this pass (the cursor keeps the rest for"
                            + " a relaunch)")
                        stoppedEarly = true
                        break
                    }
                }
            }
            let settled = cursor.map { $0.summary() } ?? "no cursor"
            let complete = cursor?.isComplete ?? true
            let done = "auto: pass complete (\(cells.count) cell(s)) · \(settled)"
                + (stoppedEarly ? " · stopped early" : "")
            LadderLog.append(done)
            if complete {
                switch source {
                case .launchArgs:
                    break
                case .documents:
                    if let url = Self.autoJSONURL() {
                        let doneURL = url.deletingLastPathComponent()
                            .appendingPathComponent("auto.done.json")
                        try? FileManager.default.removeItem(at: doneURL)
                        try? FileManager.default.moveItem(at: url, to: doneURL)
                    }
                case .bundled:
                    // run-once marker, written only once the cursor has no cell
                    // left to try
                    LadderStore.markDefaultDone("cursor: \(settled)")
                }
                LadderLog.append("auto: cursor exhausted (\(settled)) — relaunch will not loop")
            } else {
                LadderLog.append("auto: cursor not exhausted (\(settled))"
                    + " — a relaunch resumes it")
            }
            Telemetry.flush()
            LadderLog.append(Telemetry.deliverySummary)
            await MainActor.run {
                self.isRunning = false
                self.dimmed = false
                self.status = done
                self.refreshLog()
            }
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    /// The cursor on disk is always one step ahead of the work.
    private nonisolated static func persist(_ cursor: LadderCursor?) {
        if let cursor { LadderStore.save(cursor) }
    }

    /// How many failures in a row end a pass.
    private nonisolated static let consecutiveFailureStop = 3

    /// One machine-readable line per ladder cell (v0.4 field names kept).
    private nonisolated static func autoResult(_ s: RunStats, _ cell: AutoCell) -> String {
        let sorted = s.stepMillis.sorted()
        let med = sorted.isEmpty ? 0 : sorted[max(0, sorted.count / 2 - 1)]
        return "AUTO-RESULT units=\(s.units) model=\(cell.variant.rawValue)"
            + " steps=\(s.stepMillis.count)"
            + " median_step_ms=" + String(format: "%.0f", med)
            + " median_forward_ms=" + String(format: "%.0f", med)
            + " peak_mem_mb=" + String(format: "%.0f", s.peakMemMB)
            + " total_s=" + String(format: "%.1f", s.total)
            + " canvas=" + s.canvas
    }

    /// Renders land in Documents/renders/ so the grading round can pull them
    /// over AFC/Finder without another share sheet (naming unchanged).
    private nonisolated static func saveRender(_ image: UIImage, cell: AutoCell, seed: UInt64) -> String? {
        guard let data = image.pngData() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let name = "\(cell.units.rawValue)_\(cell.variant.rawValue)_s\(cell.steps)"
            + "_seed\(seed)_\(formatter.string(from: Date()))"
        return RenderStore.savePNG(data, name: name)
    }
}
