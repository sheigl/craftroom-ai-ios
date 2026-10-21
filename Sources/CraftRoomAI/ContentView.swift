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

    private let engine = Engine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Craft Room AI — Phase A")
                    .font(.largeTitle.bold())

                controls
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

    // MARK: run

    private func run() {
        guard let photo else { return }
        let seed = UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        running = true
        stats = ""
        let units = self.units
        let guidance = self.guidance
        Task.detached(priority: .userInitiated) {
            do {
                let stage: (String) -> Void = { msg in
                    Task { await MainActor.run { status = msg } }
                }
                let (img, s) = try await engine.run(units: units, photo: photo,
                                                     seed: seed,
                                                     guidance: Float(guidance),
                                                     onStage: stage)
                await MainActor.run {
                    running = false
                    result = img
                    status = "Done."
                    stats = Self.format(s)
                }
            } catch {
                await MainActor.run {
                    running = false
                    status = "Run failed: \(error.localizedDescription)"
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
             guidance: Float,
             onStage: @escaping (String) -> Void) throws -> (UIImage, RunStats) {
        if inference == nil || loadedUnits != units {
            onStage("Loading models (\(units.rawValue))…")
            let inf = try Inference()
            let load = try inf.loadModels(units: units)
            inference = inf
            loadedUnits = units
            lastLoad = load
        }
        guard let inference else { throw PipError.model("engine not ready") }
        var (img, stats) = try inference.generate(from: photo, seed: seed,
                                                  guidance: guidance, onStage: onStage)
        stats.modelLoad = lastLoad
        stats.units = units.rawValue
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

    final class Coordinator: NSObject, UIImagePickerControllerDelegate {
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
