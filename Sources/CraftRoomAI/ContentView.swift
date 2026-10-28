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

    // MARK: auto mode (remote ladder driver)
    //
    // Launched via the developer tunnel with
    //   --auto --units=all|cpu_gpu|cpu_only --guidance=1.0 --max-steps=2 --seed=0
    // the harness picks the bundled test photo and runs a ladder cell with zero
    // taps; timing results land as one AUTO-RESULT line in phaseA.log. Timing is
    // content-independent (geometry is fixed), so the synthetic photo is fine.

    private struct AutoConfig {
        var units: ComputeUnitsOption
        var guidance: Double
        var seed: UInt64
        var maxSteps: Int
    }

    @State private var autoStarted = false
    @State private var autoWaitLogged = false

    private func autoConfig() -> AutoConfig? {
        let a = CommandLine.arguments
        guard a.contains("--auto") else { return nil }
        func val(_ key: String) -> String? {
            guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
            return a[i + 1]
        }
        let units: ComputeUnitsOption
        switch val("--units") {
        case "cpu_gpu":  units = .cpuAndGPU
        case "cpu_only": units = .cpuOnly
        default:         units = .all
        }
        return AutoConfig(
            units: units,
            guidance: Double(val("--guidance") ?? "3.0") ?? 3.0,
            seed: UInt64(val("--seed") ?? "0") ?? 0,
            maxSteps: max(1, min(30, Int(val("--max-steps") ?? "30") ?? 30)))
    }

    private func maybeStartAuto() {
        guard !autoStarted, let ac = autoConfig() else { return }
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
        run(preferredPhoto: img, preferredUnits: ac.units,
            preferredGuidance: ac.guidance, preferredSeed: ac.seed,
            maxSteps: ac.maxSteps)
        // after run()'s Diagnostics.reset so the line survives into the log
        Diagnostics.log("auto: units=\(ac.units.rawValue) guidance="
            + String(format: "%.1f", ac.guidance) + " seed=\(ac.seed)"
            + " max-steps=\(ac.maxSteps)")
    }

    // MARK: run

    // Optional preferred* args let auto-mode (launch args) drive a run with no
    // taps; the button path passes nothing and reads UI state as before.
    private func run(preferredPhoto: UIImage? = nil,
                     preferredUnits: ComputeUnitsOption? = nil,
                     preferredGuidance: Double? = nil,
                     preferredSeed: UInt64? = nil,
                     maxSteps: Int = 30) {
        guard let photo = preferredPhoto ?? photo else { return }
        let seed = preferredSeed
            ?? UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        running = true
        stats = ""
        status = "Starting…"
        stage = "start"
        let units = preferredUnits ?? self.units
        let guidance = preferredGuidance ?? self.guidance
        let force = self.forceLoad
        Diagnostics.reset("run on \(units.rawValue) guidance \(String(format: "%.1f", guidance))"
            + " seed \(seed) photo \(Int(photo.size.width))x\(Int(photo.size.height))"
            + (maxSteps < 30 ? " max-steps \(maxSteps)" : ""))
        Task.detached(priority: .userInitiated) {
            // boxed local: the same thread writes it in the sink and reads it in
            // the catch, and reading @State off-main would be unsound
            var lastStage = "start"
            do {
                let stageSink: (String) -> Void = { msg in
                    lastStage = msg
                    Diagnostics.log("stage: " + msg)
                    Task { await MainActor.run {
                        status = msg
                        stage = msg
                    } }
                }
                let (img, s) = try await engine.run(units: units, photo: photo,
                                                    seed: seed,
                                                    guidance: Float(guidance),
                                                    forceLoad: force,
                                                    onStage: stageSink,
                                                    maxSteps: maxSteps)
                await MainActor.run {
                    running = false
                    result = img
                    status = "Done."
                    stats = Self.format(s)
                    logText = Diagnostics.tail()
                    if maxSteps < 30 || preferredUnits != nil {
                        // one machine-readable line for the remote ladder reader
                        let fw: Double = guidance > 1 ? 2 : 1
                        let med = s.stepMillis.sorted()[max(0, s.stepMillis.count / 2 - 1)]
                        Diagnostics.log("AUTO-RESULT units=\(s.units) guidance="
                            + String(format: "%.1f", guidance)
                            + " steps=\(s.stepMillis.count)"
                            + " median_step_ms=" + String(format: "%.0f", med)
                            + " median_forward_ms=" + String(format: "%.0f", med / fw)
                            + " peak_mem_mb=" + String(format: "%.0f", s.peakMemMB))
                    }
                }
            } catch {
                let msg = error.localizedDescription
                let failedAt = lastStage   // immutable copy for the @Sendable hop
                Diagnostics.log("ERROR at \(failedAt): \(msg)")
                await MainActor.run {
                    running = false
                    status = "\(failedAt) failed: \(msg)"
                    logText = Diagnostics.tail()
                }
            }
        }
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
