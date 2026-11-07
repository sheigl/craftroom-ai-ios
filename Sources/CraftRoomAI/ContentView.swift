import SwiftUI
import UIKit
import CraftRoomCore

struct ContentView: View {
    @State private var photo: UIImage?
    @State private var result: UIImage?
    @State private var status = "Pick a photo to begin."
    @State private var stats = ""
    @State private var running = false
    @State private var units: ComputeUnitsOption = .all
    @State private var variant: AttentionVariant = .sdpa
    @State private var steps: Int = Spatial.defaultSteps
    @State private var showPicker = false
    @State private var seedText = "42"
    /// Default ON: a kill still leaves the budget-vs-weights line in the log,
    /// which IS the measurement, so we attempt and log rather than refuse.
    @State private var forceLoad = true
    @State private var logText = ""
    @State private var payload: PayloadState = .checking
    @State private var verdict = ""
    @State private var stage = "start"
    @State private var savedName = ""

    private let engine = Engine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Craft Room AI — device v2")
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
                        Text("Result")
                            .font(.headline)
                        Image(uiImage: result)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, minHeight: 320)
                        HStack {
                            Button("Save PNG") { save(result) }
                                .buttonStyle(.bordered)
                            if !savedName.isEmpty {
                                Text(savedName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
            variant = AttentionVariant(rawValue: PayloadStore.shared.variant) ?? .sdpa
            if case .missing = payload, autoLadder() != nil {
                // Unattended run (bundled or pushed ladder): start the payload
                // download with no tap. Build 9's whole point is that opening
                // the app is the only gesture the T5 checklist needs.
                Diagnostics.log("auto: payload missing, starting download unattended")
                Telemetry.send("auto: payload missing, starting download unattended "
                               + "(base \(PayloadStore.shared.baseURL))")
                startDownload()
            }
            maybeStartAuto()
        }
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

    // MARK: payload

    private var payloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Attention", selection: $variant) {
                    ForEach(AttentionVariant.allCases) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(running)
            }
            Text("base: \(PayloadStore.shared.baseURL)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let override = PayloadStore.shared.overrideSource {
                Text("override: \(override)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            switch payload {
            case .checking:
                Text("Checking installed models…").foregroundStyle(.secondary)
            case .missing(let totalMB):
                Text("Models not installed").font(.headline)
                Text(String(format: "This build downloads %.2f GB of the device-v2 payload (%@). Run it on Wi-Fi; the screen is held awake automatically. An interrupted file resumes where it stopped (the `.part` bytes are reused when the server supports Range).",
                            Double(totalMB) / 1024, variant.label))
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

    private func startDownload() {
        PayloadStore.shared.variant = variant.rawValue
        let totalMB = (PayloadStore.shared.manifestV2
            .flatMap { try? $0.bytes(forVariant: variant.rawValue) } ?? 0) / 1_048_576
        payload = .downloading(fraction: 0, doneMB: 0, totalMB: totalMB)
        status = "Downloading models…"
        Telemetry.send("payload: download start, base \(PayloadStore.shared.baseURL) "
                       + "variant \(variant.rawValue) (~\(totalMB / 1024) GB)")
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
                maybeStartAuto()
                status = "Models installed. Pick a photo to begin."
                logText = Diagnostics.tail()
                Telemetry.send("payload: installed \(variant.rawValue), "
                               + "starting ladder check")
            } catch {
                poll.cancel()
                let msg = error.localizedDescription
                Diagnostics.log("payload download failed: \(msg)")
                Telemetry.send("payload download failed: \(msg) "
                               + "(base \(PayloadStore.shared.baseURL))")
                payload = .failed(msg)
                status = "Download failed."
            }
        }
    }

    // MARK: controls

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
            Picker("Units", selection: $units) {
                ForEach(ComputeUnitsOption.allCases) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .disabled(running)
            Picker("Attention", selection: $variant) {
                ForEach(AttentionVariant.allCases) { v in
                    Text(v.label).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .disabled(running)
            .onChange(of: variant) { _, new in
                PayloadStore.shared.variant = new.rawValue
                payload = PayloadStore.shared.state
            }
            Picker("Steps", selection: $steps) {
                ForEach([1, 5, 30], id: \.self) { n in
                    Text("\(n)").tag(n)
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
                    Text("Generate").font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(photo == nil)
            }
        }
    }

    // MARK: auto mode (unattended ladder)

    // Two ways in, both needing no taps beyond launching the app:
    //  1. launch args: --auto --units=all|cpu_only|ane --model=sdpa|split_einsum
    //                  --steps=30 --seed=42
    //  2. Documents/auto.json:
    //       {"cells":[{"units":"all","model":"sdpa","steps":1,"seed":42}, …]}
    //  3. (build 9, no USB) bundled auto_default.json — units × attention ×
    //     steps full matrix, runs once; Documents/auto_default.done marks it.
    // Cells run back to back; each ends with one AUTO-RESULT line in
    // Documents/ladder.log (never truncated), then auto.json becomes
    // auto.done.json (or the done marker is written) so a relaunch does not
    // repeat the ladder. Timing is
    // content-independent (fixed graph), so the bundled test photo is enough.
    // The screen is held awake by the app itself and painted black.
    // Every ladder.log line is also POSTed to the LAN collector (Telemetry).

    struct AutoCell {
        var units: ComputeUnitsOption
        var variant: AttentionVariant
        var steps: Int
        var seed: UInt64

        var label: String { "\(units.rawValue)/\(variant.rawValue)/\(steps)" }
    }

    @State private var autoStarted = false
    @State private var autoWaitLogged = false
    @State private var autoDim = false

    private static func units(from s: String?) -> ComputeUnitsOption {
        switch s {
        case "cpu_only", "cpuOnly": return .cpuOnly
        case "ane", "cpuAndNeuralEngine": return .cpuAndNeuralEngine
        default: return .all
        }
    }

    private static func variant(from s: String?) -> AttentionVariant {
        AttentionVariant(rawValue: s ?? "") ?? .sdpa
    }

    enum AutoSource { case launchArgs, documents, bundled }

    private static func autoJSONURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("auto.json")
    }

    /// Written after a BUNDLED ladder completes so a relaunch never repeats
    /// the hours-long matrix (the pushed-file equivalent is the rename to
    /// auto.done.json).
    private static func autoDefaultDoneURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("auto_default.done")
    }

    /// `{"cells":[{units, model, steps, seed}, …]}` — same protocol for the
    /// pushed auto.json and the bundled auto_default.json.
    private static func parseCells(_ data: Data) -> [AutoCell]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["cells"] as? [[String: Any]], !raw.isEmpty else { return nil }
        return raw.map { c in
            AutoCell(units: Self.units(from: c["units"] as? String),
                     variant: Self.variant(from: c["model"] as? String),
                     steps: max(1, min(30, (c["steps"] as? NSNumber)?.intValue
                                        ?? (c["maxSteps"] as? NSNumber)?.intValue ?? 30)),
                     seed: (c["seed"] as? NSNumber)?.uint64Value ?? 42)
        }
    }

    /// Ladder cells and their source. Priority: launch args →
    /// Documents/auto.json (still wins) → bundled auto_default.json, which is
    /// skipped once auto_default.done marks a finished run.
    private func autoLadder() -> (cells: [AutoCell], source: AutoSource)? {
        if let single = launchArgCell() { return ([single], .launchArgs) }
        if let url = Self.autoJSONURL(),
           let data = try? Data(contentsOf: url),
           let cells = Self.parseCells(data) { return (cells, .documents) }
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
        return AutoCell(units: Self.units(from: val("--units")),
                        variant: Self.variant(from: val("--model")),
                        steps: max(1, min(30, Int(val("--steps") ?? "30") ?? 30)),
                        seed: UInt64(val("--seed") ?? "42") ?? 42)
    }

    private func maybeStartAuto() {
        guard !autoStarted, let auto = autoLadder() else { return }
        let cells = auto.cells
        guard case .ready = payload else {
            if !autoWaitLogged {
                autoWaitLogged = true
                Diagnostics.log("auto: waiting for payload install")
                Telemetry.send("auto: waiting for payload install (base \(PayloadStore.shared.baseURL))")
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
        let startLine = "auto: \(cells.count) cell(s) [\(auto.source)] — "
            + cells.map(\.label).joined(separator: " · ")
        run(preferredPhoto: img, ladder: cells, ladderSource: auto.source)
        Diagnostics.log(startLine)
        Telemetry.send(startLine)
    }

    // MARK: run

    private func run(preferredPhoto: UIImage? = nil, ladder: [AutoCell]? = nil,
                     ladderSource: AutoSource = .documents) {
        guard let photo = preferredPhoto ?? photo else { return }
        let cells = ladder ?? [AutoCell(
            units: units,
            variant: variant,
            steps: steps,
            seed: UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 42)]
        let auto = ladder != nil
        let force = forceLoad
        running = true
        Task.detached(priority: .userInitiated) {
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
            var aborted = false
            for (idx, cell) in cells.enumerated() {
                if aborted { break }
                var lastStage = "start"
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
                    let (img, s) = try await engine.run(units: cell.units,
                                                        variant: cell.variant,
                                                        photo: photo,
                                                        seed: cell.seed,
                                                        forceLoad: force,
                                                        onStage: stageSink,
                                                        steps: cell.steps)
                    var saved: String?
                    if auto || ladder != nil {
                        saved = Self.saveRender(img, cell: cell, seed: cell.seed)
                    }
                    let line = auto ? Self.autoResult(s, cell) : ""
                    await MainActor.run {
                        result = img
                        status = "Done."
                        stats = Self.format(s)
                        if let saved { savedName = saved }
                        if !line.isEmpty {
                            Diagnostics.log(line)
                            Self.appendLadder(line)
                        }
                        logText = Diagnostics.tail()
                    }
                } catch {
                    let msg = error.localizedDescription
                    let failedAt = lastStage
                    Diagnostics.log("ERROR at \(failedAt): \(msg)")
                    Telemetry.send("ERROR at \(failedAt): \(msg)")
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
                switch ladderSource {
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
                    // run-once marker: the bundled matrix must not restart on
                    // a relaunch (mirrors the auto.json → auto.done.json move)
                    if let marker = Self.autoDefaultDoneURL() {
                        let text = "auto_default ladder complete \(Date())\n"
                        try? text.data(using: .utf8)?.write(to: marker, options: .atomic)
                    }
                }
            }
            await MainActor.run {
                running = false
                autoDim = false
                logText = Diagnostics.tail()
            }
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    /// Durable copy of the ladder results: phaseA.log is reset per launch, so
    /// the cells also accumulate here (never truncated). Every line is also
    /// POSTed to the LAN collector (fire-and-forget), which is how the T5
    /// orchestrator watches the ladder without a USB cable.
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
        Telemetry.send(line)
    }

    /// One machine-readable line per ladder cell. Keeps the v0.4 field names
    /// (`units=`, `median_forward_ms=`, `peak_mem_mb=`) and adds `model=` and
    /// `steps=`; batch 2 means one forward per step, so step == forward time.
    private static func autoResult(_ s: RunStats, _ cell: AutoCell) -> String {
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

    /// Renders land in Documents/renders/ so the T6 grading round can pull them
    /// over AFC/Finder without another share sheet.
    private static func saveRender(_ image: UIImage, cell: AutoCell, seed: UInt64) -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first,
              let data = image.pngData() else { return nil }
        let dir = docs.appendingPathComponent("renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        let name = "\(cell.units.rawValue)_\(cell.variant.rawValue)_s\(cell.steps)"
            + "_seed\(seed)_\(f.string(from: Date())).png"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return "renders/\(name)"
        } catch {
            Diagnostics.log("ERROR saving render: \(error.localizedDescription)")
            return nil
        }
    }

    private func save(_ image: UIImage) {
        let cell = AutoCell(units: units, variant: variant, steps: steps, seed: 0)
        savedName = Self.saveRender(image, cell: cell, seed: 0) ?? ""
    }

    static func format(_ s: RunStats) -> String {
        let ms = s.stepMillis
        let avg = ms.isEmpty ? 0.0 : ms.reduce(0, +) / Double(ms.count)
        let fastest = ms.min() ?? 0
        let slowest = ms.max() ?? 0
        return """
        units:          \(s.units)
        model:          \(s.variant)
        steps:          \(s.steps) (\(s.forwards) forwards, batch 2)
        canvas:         \(s.canvas)
        model load:     \(sec(s.modelLoad))
        prep+canny:     \(sec(s.encode))
        loop:           \(sec(s.loop))
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

/// Owns the loaded models across runs. The UNet must be reloaded when the
/// compute-unit set or the attention variant changes; the VAE never does.
final class Engine {
    private var inference: Inference?
    private var loadedUnits: ComputeUnitsOption?
    private var loadedVariant: AttentionVariant?
    private var lastLoad: Double = 0

    func run(units: ComputeUnitsOption, variant: AttentionVariant, photo: UIImage,
             seed: UInt64, forceLoad: Bool,
             onStage: @escaping (String) -> Void,
             steps: Int = Spatial.defaultSteps) throws -> (UIImage, RunStats) {
        if inference == nil || loadedUnits != units || loadedVariant != variant {
            onStage("Loading \(variant.label) on \(units.label)…")
            let inf = Inference()
            lastLoad = try inf.loadModels(units: units, variant: variant, force: forceLoad)
            inference = inf
            loadedUnits = units
            loadedVariant = variant
        }
        guard let inference else { throw PipError.model("engine not ready") }
        var (img, stats) = try inference.generate(from: photo, seed: seed,
                                                 steps: steps, onStage: onStage)
        stats.modelLoad = lastLoad
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
