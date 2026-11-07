import Foundation
import CraftRoomCore

/// The durable ladder record and the crash cursor — everything about a run that
/// has to survive a jetsam kill.
///
/// Two files, both in `Documents/` (UIFileSharingEnabled makes them reachable
/// from Files, and build 9 added the wireless copy of every line):
///
///  * `ladder.log`  — never truncated, one line per fact (`CELL`, `START`,
///    `AUTO-RESULT`, `AUTO-SKIP`, `AUTO-FAIL`, `SELFTEST`), mirrored to the LAN
///    collector in order.
///  * `ladder_cursor.json` — the `LadderCursor` (see CraftRoomCore): written
///    **before** a cell starts, so a restart knows which cell killed the
///    process and how many attempts it already used.
enum LadderLog {
    /// Results-table line: `ladder.log` + ordered telemetry.
    static func append(_ line: String) {
        Diagnostics.log(line)
        guard let url = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first?
            .appendingPathComponent("ladder.log") else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        Telemetry.send(line)
    }

    /// Instrumentation line: `phaseA.log` + telemetry, but *not* the results
    /// table (footprint watchdog, selftest, compile, stage lines).
    static func instrument(_ line: String) {
        Diagnostics.log(line)
        Telemetry.send(line)
    }
}

/// Load/save of `Documents/ladder_cursor.json`.
enum LadderStore {
    static var cursorURL: URL? {
        PayloadStore.documentsURL?.appendingPathComponent("ladder_cursor.json")
    }

    /// Written when the **bundled** matrix is finished (every cell settled, not
    /// necessarily succeeded) so a relaunch never re-enumerates it.
    static var defaultDoneURL: URL? {
        PayloadStore.documentsURL?.appendingPathComponent("auto_default.done")
    }

    /// The cursor for this exact ladder, or nil when there is none, it cannot
    /// be read, or it belongs to a different matrix (a re-ordered
    /// `auto_default.json`, a different `auto.json`).
    static func load(matching ladderID: String) -> LadderCursor? {
        guard let url = cursorURL, let data = try? Data(contentsOf: url),
              let cursor = try? LadderCursor.decode(data), cursor.ladderID == ladderID
        else { return nil }
        return cursor
    }

    /// Atomic write. Called before a cell starts and after every state change:
    /// the whole point is that the file is ahead of the work.
    static func save(_ cursor: LadderCursor) {
        guard let url = cursorURL, let data = try? cursor.json() else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        if let url = cursorURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Marks the bundled matrix as finished for this launch generation.
    static func markDefaultDone(_ note: String) {
        guard let url = defaultDoneURL else { return }
        let text = "auto_default ladder complete \(Date())\n\(note)\n"
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

/// Build-10 footprint watchdog.
///
/// A jetsam kill inside `MLModel(contentsOf:)` leaves no exception, no crash
/// report and — in build 9 — no log line after `load: …`. The climb is the only
/// thing that can tell hypothesis A (the CPU backend de-palettizes the 6-bit
/// weights into a ~7.1 GiB resident fp16 copy → the kill is a memory kill) from
/// hypothesis B (a macOS-compiled `.mlmodelc` that iOS refuses to load): A
/// climbs steadily until the ceiling, B sits flat and then dies or throws.
///
/// So: while a blocking load is in flight, one background thread logs
/// `load in flight model=… footprint=NNN MB` every 2 s, to `phaseA.log` and to
/// the collector. `grep "load in flight"` shows the climb.
final class LoadWatchdog {
    private let model: String
    private let phase: String
    private let lock = NSLock()
    private var stopped = false
    private let start = Date()

    private init(model: String, phase: String) {
        self.model = model
        self.phase = phase
    }

    /// Starts watching one model load and emits the t=0 line immediately.
    static func start(model: String, phase: String) -> LoadWatchdog {
        let watch = LoadWatchdog(model: model, phase: phase)
        watch.emit()
        DispatchQueue.global(qos: .utility).async {
            while true {
                usleep(2_000_000)
                watch.lock.lock()
                let done = watch.stopped
                watch.lock.unlock()
                if done { return }
                watch.emit()
            }
        }
        return watch
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private func emit() {
        let free = Diagnostics.availableMemoryMB().map { String(format: "%.0f", $0) } ?? "n/a"
        LadderLog.instrument(String(format: "load in flight model=%@ phase=%@ elapsed=%.0fs"
            + " footprint=%.0f MB headroom=%@ MB",
            model, phase, Date().timeIntervalSince(start),
            Diagnostics.footprintMB(), free))
    }
}

/// Build-10 self-test: prove the payload's *provenance* is usable before
/// spending a 2.9 GB load on the question.
///
/// `VAEDecoder_sdxl_fp32` (198 MB, same macOS runner, same compile step, same
/// download path as the UNet) is loaded and pushed through one dummy forward,
/// once per launch, before cell 1:
///
///  * `SELFTEST vae load=… forward=…` OK   → the `.mlmodelc` provenance works on
///    this iOS, so a UNet kill is about the UNet (memory / palettization), not
///    about compiled models in general.
///  * `SELFTEST FAILED …`                  → hypothesis B: flip the manifest to
///    `form: "mlpackage"` (plan B, see `DeviceCompiler`) and re-run.
enum SelfTest {
    struct Outcome {
        let loadSeconds: Double
        let forwardSeconds: Double
        /// Peak footprint reached while the decoder was loaded.
        let footprintMB: Double
    }

    private static var done = false

    /// Runs once per launch; returns nil on subsequent calls.
    static func runVAEOnce() -> Outcome? {
        guard !done else { return nil }
        done = true
        do {
            let out = try vaePass()      // the MLModel dies when vaePass returns
            let idle = Diagnostics.footprintMB()
            LadderLog.append(String(format:
                "SELFTEST vae load=%.2fs forward=%.2fs footprint=%.0f MB released=%.0f MB"
                + " (VAEDecoder_sdxl_fp32 cpuAndGPU · compiled-form provenance OK)",
                out.loadSeconds, out.forwardSeconds, out.footprintMB, idle))
            return out
        } catch {
            LadderLog.append("SELFTEST FAILED vae error="
                + error.localizedDescription
                + " — compiled-form provenance suspect (plan B: manifest form=mlpackage)")
            return nil
        }
    }

    /// One load + one dummy forward. `MLModel` is local on purpose: returning
    /// from here is what frees the ~400 MB again, so the caller can measure the
    /// release and prove the selftest does not eat the ladder's headroom.
    private static func vaePass() throws -> Outcome {
        let t0 = Date()
        let model = try Inference.loadModel(named: "VAEDecoder_sdxl_fp32",
                                            units: .cpuAndGPU, phase: "selftest")
        let load = Date().timeIntervalSince(t0)
        let t1 = Date()
        // smallest legal forward: 1×4×96×96 fp32 zeros → a 768² frame
        let zeros = try Inference.f32Array(shape: [1, 4, 96, 96],
                                           values: [Float](repeating: 0,
                                                           count: 4 * 96 * 96))
        _ = try Inference.predict(model, ["latents": zeros])
        let forward = Date().timeIntervalSince(t1)
        return Outcome(loadSeconds: load, forwardSeconds: forward,
                       footprintMB: Diagnostics.footprintMB())
    }
}
