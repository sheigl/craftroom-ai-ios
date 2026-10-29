import SwiftUI
import UIKit

struct ContentView: View {
    @State private var photo: UIImage?
    @State private var result: UIImage?
    @State private var status = "Pick a photo to begin."
    @State private var stats = ""
    @State private var running = false
    @State private var units: ComputeUnitsOption = .all
    @State private var showPicker = false
    @State private var seedText = "0"
    // ladder verdict: guidance 3.0 is the ship setting (2.0 fallback); the
    // picker lets one device run measure 1.0 (30 forwards) vs 3.0 (60 forwards)
    @State private var guidance: Double = 3.0
    /// Default ON: a kill still leaves the budget-vs-weights line in the log,
    /// which IS the measurement — so we attempt and log rather than refuse.
    /// Turning it off makes the preflight stop the run instead (safe mode for
    /// a demo where a crash would be embarrassing).
    @State private var forceLoad = true
    /// Tail of Documents/phaseA.log, shown on screen so the evidence never
    /// depends on the Files folder being exposed.
    @State private var logText = ""
    /// Models are fetched on first launch (ITMS-90558 moved them out of the
    /// bundle); this gates the whole UI until they are installed.
    @State private var payload: PayloadState = .checking
    /// Precomputed once (it stats every bundled weight file).
    @State private var verdict = ""
    /// Last pipeline stage reached — an error is reported against it, and a
    /// kill leaves it in phaseA.log.
    @State private var stage = "start"

    private let engine = Engine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Craft Room AI — Phase A")
                    .font(.largeTitle.bold())
                Text("\(Diagnostics.build) · \(Diagnostics.summary())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !verdict.isEmpty {
                    Text(verdict)
                        .font(.caption.bold())
                        .foregroundStyle(verdict.contains("IMPOSSIBLE") ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }

                if payload == .ready {
                    controls
                } else {
                    payloadCard
                }
                Text(status)
                    .font(.title3)
                    .foregroundStyle(status.contains("failed") ? Color.red : Color.primary)
                if let result {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Result (768×768)")
                            .font(.headline)
                        Image(uiImage: result)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                if !stats.isEmpty {
                    Text(stats)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                logPanel
            }
            .padding()
        }
        .sheet(isPresented: $showPicker) {
            ImagePicker { picked in
                photo = picked
                result = nil
                stats = ""
                status = "Photo ready. Tap Generate."
            }
        }
        .task {
            verdict = Diagnostics.memoryVerdict()
            logText = Diagnostics.tail()
            payload = PayloadStore.shared.state
            maybeStartAuto()
        }
        // unattended ladder: paint the panel black (it is held awake for the
        // duration, so keep the light down); also blocks stray taps mid-cell
        .overlay {
            if autoDim {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 8) {
                        Text("auto ladder running")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.gray.opacity(0.6))
                    }
                }
            }
        }
    }

    /// The log tail, on screen. A screenshot of this is enough to diagnose a
    /// run, which matters because the Files folder depends on a correct
    /// Info.plist (see the v0.3.0 packaging fix).
    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Button("Reload") { logText = Diagnostics.tail() }
                    .buttonStyle(.bordered)
                Button("Copy") { UIPasteboard.general.string = logText }
                    .buttonStyle(.bordered)
            }
            Text(logText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ITMS-90558: Apple refuses a 4 GB-thinned bundle, so the three compiled
    /// .mlmodelc models are downloaded on first launch from the public HF
    /// payload repo (device_manifest.json rides in the app; PayloadStore
    /// mirrors it into Application Support and sha256-verifies every file).
    private var payloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch payload {
            case .checking:
                Text("Checking installed models…").foregroundStyle(.secondary)
            case .missing(let totalMB):
                Text("Models not installed").font(.headline)
                Text(String(format: "This build downloads %.2f GB of models from the CDN. Run it on Wi-Fi; the screen is held awake automatically. Interrupted downloads resume per file on Retry.", Double(totalMB) / 1024))
                    .foregroundStyle(.secondary)
                Button("Download models") { startDownload() }
                    .buttonStyle(.borderedProminent)
            case .downloading(let fraction, let doneMB, let totalMB):
                Text("Downloading models…").font(.headline)
                ProgressView(value: fraction)
                Text("\(doneMB) / \(totalMB) MB")
                    .font(.system(.body, design: .monospaced))
                Button("Cancel", role: .destructive) { PayloadStore.shared.cancel() }
            case .failed(let msg):
                Text("Download failed").font(.headline)
                Text(msg)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("Retry download") { startDownload() }
                    .buttonStyle(.borderedProminent)
            case .ready:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    /// Drives PayloadStore.downloadAll and polls its byte counters for the UI
    /// (the URLSession delegate runs off-main, so state hops back here).
    private func startDownload() {
        let totalMB = (PayloadStore.shared.manifest?.totalBytes ?? 0) / 1_048_576
        payload = .downloading(fraction: 0, doneMB: 0, totalMB: totalMB)
        status = "Downloading models…"
        Task {
            let dl = Task { try await PayloadStore.shared.downloadAll() }
            let poll = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    let s = PayloadStore.shared.snapshot()
                    await MainActor.run {
                        payload = .downloading(
                            fraction: Double(s.done) / Double(max(s.total, 1)),
                            doneMB: s.done / 1_048_576,
                            totalMB: s.total / 1_048_576)
                    }
                }
            }
            do {
                try await dl.value
                poll.cancel()
                payload = .ready
                verdict = Diagnostics.memoryVerdict()
                maybeStartAuto()   // first-launch auto cell starts when the payload lands
                status = "Models installed. Pick a photo to begin."
                logText = Diagnostics.tail()
            } catch {
                poll.cancel()
                let msg = error.localizedDescription
                Diagnostics.log("payload download failed: \(msg)")
                payload = .failed(msg)
                status = "Download failed."
            }
        }
    }

    // MARK: pieces

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose photo") { showPicker = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .frame(width: 96, height: 64)
                        .clipShape(.rect)
                }
            }
            Picker("Compute", selection: $units) {
                ForEach(ComputeUnitsOption.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            Picker("Guidance", selection: $guidance) {
                ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { g in
                    Text(String(format: "%.1f", g)).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .disabled(running)
            Toggle("Load even if the preflight says impossible", isOn: $forceLoad)
                .disabled(running)
            HStack {
                Text("Seed")
                TextField("seed", text: $seedText)
                    .frame(width: 90)
                    .disabled(running)
            }
            if running {
                ProgressView()
            } else {
                Button {
                    run()
                } label: {
                    Text("Generate")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(photo == nil)
            }
        }
    }

    // MARK: auto mode (unattended ladder driver)
    //
    // Two ways in, both needing no taps beyond launching the app:
    //  1. launch args (developer tunnel/DVT):
    //       --auto --units=all|cpu_gpu|cpu_only --guidance=1.0 --max-steps=2
    //  2. Documents/auto.json, written over AFC from the relay box:
    //       {"cells":[{"units":"all","guidance":1.0,"maxSteps":1}, ...]}
    // Cells run back to back; each ends with one AUTO-RESULT line in
    // phaseA.log, then the file is renamed auto.done.json so a relaunch does
    // not repeat the ladder. Timing is content-independent (fixed geometry), so
    // the bundled synthetic test photo is enough. The screen is held awake for
    // the duration by the app itself (no Auto-Lock change) and painted black.

    private struct AutoCell {
        var units: ComputeUnitsOption
        var guidance: Double
        var seed: UInt64
        var maxSteps: Int
        var label: String {
            "\(units.rawValue) guidance \(String(format: "%.1f", guidance))"
                + (maxSteps < 30 ? " max-steps \(maxSteps)" : "")
        }
    }

    @State private var autoStarted = false
    @State private var autoWaitLogged = false
    @State private var autoDim = false

    private static func units(from s: String?) -> ComputeUnitsOption {
        switch s {
        case "cpu_gpu":  return .cpuAndGPU
        case "cpu_only": return .cpuOnly
        default:         return .all
        }
    }

    private static func autoJSONURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("auto.json")
    }

    /// Launch args first, then Documents/auto.json (a cell list).
    private func autoLadder() -> [AutoCell]? {
        if let single = launchArgCell() { return [single] }
        guard let url = Self.autoJSONURL(),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["cells"] as? [[String: Any]], !raw.isEmpty else { return nil }
        return raw.map { c in
            AutoCell(units: Self.units(from: c["units"] as? String),
                     guidance: (c["guidance"] as? NSNumber)?.doubleValue ?? 3.0,
                     seed: (c["seed"] as? NSNumber)?.uint64Value ?? 0,
                     maxSteps: max(1, min(30, (c["maxSteps"] as? NSNumber)?.intValue ?? 30)))
        }
    }

    private func launchArgCell() -> AutoCell? {
        let a = CommandLine.arguments
        guard a.contains("--auto") else { return nil }
        func val(_ key: String) -> String? {
            guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
            return a[i + 1]
        }
        return AutoCell(units: Self.units(from: val("--units")),
                        guidance: Double(val("--guidance") ?? "3.0") ?? 3.0,
                        seed: UInt64(val("--seed") ?? "0") ?? 0,
                        maxSteps: max(1, min(30, Int(val("--max-steps") ?? "30") ?? 30)))
    }

    private func maybeStartAuto() {
        guard !autoStarted, let cells = autoLadder() else { return }
        guard case .ready = payload else {
            if !autoWaitLogged {
                autoWaitLogged = true
                Diagnostics.log("auto: waiting for payload install")
            }
            return
        }
        autoStarted = true
        guard let url = Bundle.main.url(forResource: "test_photo", withExtension: "jpg"),
              let img = UIImage(contentsOfFile: url.path) else {
            Diagnostics.log("ERROR auto: bundled test_photo.jpg missing")
            return
        }
        autoDim = true
        run(preferredPhoto: img, ladder: cells)
        // after run()'s Diagnostics.reset so the line survives into the log
        Diagnostics.log("auto: \(cells.count) cell(s) — "
            + cells.map(\.label).joined(separator: " · "))
    }

    // MARK: run

    /// The Generate button and the auto ladder share this. `ladder` means
    /// unattended: cells back to back, black screen, screen held awake.
    private func run(preferredPhoto: UIImage? = nil,
                     preferredUnits: ComputeUnitsOption? = nil,
                     preferredGuidance: Double? = nil,
                     preferredSeed: UInt64? = nil,
                     maxSteps: Int = 30,
                     ladder: [AutoCell]? = nil) {
        guard let photo = preferredPhoto ?? photo else { return }
        let cells = ladder ?? [AutoCell(
            units: preferredUnits ?? units,
            guidance: preferredGuidance ?? guidance,
            seed: preferredSeed
                ?? UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            maxSteps: maxSteps)]
        let auto = ladder != nil || preferredUnits != nil || maxSteps < 30
        let force = self.forceLoad
        running = true
        Task.detached(priority: .userInitiated) {
            // the run must survive Auto-Lock: hold the screen awake ourselves
            // (Phase A runs are hours long; the setting stays user-controlled)
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
            var aborted = false
            for (idx, cell) in cells.enumerated() {
                if aborted { break }
                // boxed local: the same thread writes it in the sink and reads
                // it in the catch, and reading @State off-main is unsound
                var lastStage = "start"
                // reset once at ladder start: later cells must not wipe the
                // earlier AUTO-RESULT lines out of phaseA.log
                if idx == 0 {
                    Diagnostics.reset("run on \(cell.label) seed \(cell.seed)"
                        + " photo \(Int(photo.size.width))x\(Int(photo.size.height))")
                } else {
                    Diagnostics.log("=== cell \(idx + 1)/\(cells.count): \(cell.label)")
                }
                if idx == 0 && ladder != nil {
                    for cell0 in cells { Self.appendLadder("CELL \(cell0.label)") }
                }
                await MainActor.run {
                    stats = ""
                    status = "Starting…"
                    stage = "start"
                }
                do {
                    let stageSink: (String) -> Void = { msg in
                        lastStage = msg
                        Diagnostics.log("stage: " + msg)
                        Task { await MainActor.run {
                            status = msg
                            stage = msg
                        } }
                    }
                    let (img, s) = try await engine.run(units: cell.units, photo: photo,
                                                        seed: cell.seed,
                                                        guidance: Float(cell.guidance),
                                                        forceLoad: force,
                                                        onStage: stageSink,
                                                        maxSteps: cell.maxSteps)
                    let line = auto ? Self.autoResult(s, cell) : ""
                    await MainActor.run {
                        result = img
                        status = "Done."
                        stats = Self.format(s)
                        if !line.isEmpty {
                            Diagnostics.log(line)
                            Self.appendLadder(line)
                        }
                        logText = Diagnostics.tail()
                    }
                } catch {
                    let msg = error.localizedDescription
                    let failedAt = lastStage   // immutable copy for the @Sendable hop
                    Diagnostics.log("ERROR at \(failedAt): \(msg)")
                    await MainActor.run {
                        status = "\(failedAt) failed: \(msg)"
                        logText = Diagnostics.tail()
                    }
                    aborted = true
                }
            }
            if ladder != nil {
                let done = "auto: ladder complete (\(cells.count) cell(s)"
                    + (aborted ? ", aborted early" : "") + ")"
                Diagnostics.log(done)
                Self.appendLadder(done)
                // consume the config: a relaunch must not repeat the ladder
                if let url = Self.autoJSONURL() {
                    let done = url.deletingLastPathComponent()
                        .appendingPathComponent("auto.done.json")
                    try? FileManager.default.removeItem(at: done)
                    try? FileManager.default.moveItem(at: url, to: done)
                }
            }
            await MainActor.run {
                running = false
                autoDim = false
                logText = Diagnostics.tail()
            }
            // release last, so a finished ladder cannot wake the screen again
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    /// Durable copy of the ladder results: phaseA.log is reset per launch, so
    /// the cells also accumulate here (never truncated).
    private static func appendLadder(_ line: String) {
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
    }

    private static func autoResult(_ s: RunStats, _ cell: AutoCell) -> String {
        // one machine-readable line for the remote ladder reader
        let fw: Double = cell.guidance > 1 ? 2 : 1
        let med = s.stepMillis.sorted()[max(0, s.stepMillis.count / 2 - 1)]
        return "AUTO-RESULT units=\(s.units) guidance="
            + String(format: "%.1f", cell.guidance)
            + " steps=\(s.stepMillis.count)"
            + " median_step_ms=" + String(format: "%.0f", med)
            + " median_forward_ms=" + String(format: "%.0f", med / fw)
            + " peak_mem_mb=" + String(format: "%.0f", s.peakMemMB)
    }

    static func format(_ s: RunStats) -> String {
        let ms = s.stepMillis
        let avg = ms.isEmpty ? 0.0 : ms.reduce(0, +) / Double(ms.count)
        let fastest = ms.min() ?? 0
        let slowest = ms.max() ?? 0
        return """
        units:          \(s.units)
        guidance:       \(String(format: "%.1f", s.guidance))
        model load:     \(sec(s.modelLoad))
        prep:           \(sec(s.prep))
        vae encode:     \(sec(s.encode))
        loop (\(s.forwards) fwd): \(sec(s.loop))
          per step avg: \(String(format: "%.0f", avg)) ms \
        (min \(String(format: "%.0f", fastest)) / max \(String(format: "%.0f", slowest)))
        vae decode:     \(sec(s.decode))
        TOTAL:          \(String(format: "%.1f", s.total)) s
        peak footprint: \(String(format: "%.0f", s.peakMemMB)) MB
        """
    }

    private static func sec(_ t: Double) -> String {
        String(format: "%.2f", t) + " s"
    }
}

/// Owns the loaded models across runs (Phase A: models reload only when the
/// compute-unit choice changes).
final class Engine {
    private var inference: Inference?
    private var loadedUnits: ComputeUnitsOption?
    private var lastLoad: Double = 0

    func run(units: ComputeUnitsOption, photo: UIImage, seed: UInt64,
             guidance: Float, forceLoad: Bool,
             onStage: @escaping (String) -> Void,
             maxSteps: Int = 30) throws -> (UIImage, RunStats) {
        if inference == nil || loadedUnits != units {
            onStage("Loading models (\(units.rawValue))…")
            let inf = try Inference()
            let load = try inf.loadModels(units: units, force: forceLoad)
            inference = inf
            loadedUnits = units
            lastLoad = load
        }
        guard let inference else { throw PipError.model("engine not ready") }
        var (img, stats) = try inference.generate(from: photo, seed: seed,
                                                  guidance: guidance, onStage: onStage,
                                                  maxSteps: maxSteps)
        stats.modelLoad = lastLoad
        // report the set that actually ran, not the one requested (they differ
        // when a plan build failed and Inference degraded)
        stats.units = inference.effectiveUnits.rawValue
        return (img, stats)
    }
}

/// Minimal photo-library picker (battle-tested UIKit path; Info.plist carries
/// the usage string).
struct ImagePicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                onPick(img)
            }
            picker.dismiss(animated: true)
        }
    }
}
