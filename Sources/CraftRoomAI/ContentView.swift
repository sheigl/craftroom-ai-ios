import SwiftUI
import UIKit
import CraftRoomCore

/// The product screen (plan T4.8–T4.9): pick a photo, watch honest stages, see
/// the page, share it. The engine and everything diagnostic live behind
/// Settings so the first launch with no payload is a usable app, not a
/// download gate.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ladder: LadderController

    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var showResult = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    engineChip
                    photoSection
                    actionSection
                    if model.isRunning { progressCard }
                    if let message = model.errorMessage { errorCard(message) }
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    footer
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Craft Room AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showGallery = true
                    } label: {
                        Label("Gallery", systemImage: "square.grid.2x2")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                ImagePicker { picked in
                    model.setPhoto(picked)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showGallery) {
                GalleryView()
            }
            .sheet(isPresented: $showResult) {
                if let output = model.output {
                    ResultView(output: output)
                }
            }
            .onChange(of: model.output?.id) { _, newValue in
                if newValue != nil { showResult = true }
            }
        }
        .tint(Theme.accent)
        .overlay {
            // A ladder run holds the screen awake; the black overlay is what
            // build 9 shipped so the iPad is not left showing the app while it
            // measures for an hour.
            if ladder.dimmed {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 8) {
                        Text("Measuring the on-device pipeline")
                            .font(.caption)
                            .foregroundStyle(.gray)
                        Text(ladder.status)
                            .font(.caption2)
                            .foregroundStyle(.gray.opacity(0.6))
                    }
                }
            }
        }
        .task {
            model.onAppear()
            // No implicit ladder: this runs a cell only for a --auto launch
            // argument, or when the owner already tapped "Run ladder".
            ladder.runIfRequested()
        }
    }

    // MARK: engine

    private var engineChip: some View {
        HStack(spacing: 12) {
            Image(systemName: model.settings.engine == .localServer
                  ? "wifi" : "ipad")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.settings.engine.label)
                    .font(.subheadline.weight(.semibold))
                Text(engineSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Change") { showSettings = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var engineSubtitle: String {
        switch model.settings.engine {
        case .localServer:
            return model.settings.baseURL.absoluteString
        case .onDevice:
            return payloadSubtitle
        }
    }

    private var payloadSubtitle: String {
        switch model.payloadState {
        case .ready:
            return "Models installed on this iPad"
        case .missing(let totalMB):
            return "Models not downloaded (\(totalMB / 1024) GB)"
        case .downloading(let fraction, _, _):
            return String(format: "Downloading models %.0f %%", fraction * 100)
        case .failed:
            return "Model download failed"
        case .checking:
            return "Checking models…"
        }
    }

    // MARK: photo

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let photo = model.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button("Choose another photo") { showPicker = true }
                        .buttonStyle(.bordered)
                        .disabled(model.isRunning)
                    Button("Remove", role: .destructive) { model.clearPhoto() }
                        .buttonStyle(.borderless)
                        .disabled(model.isRunning)
                }
            } else {
                Button {
                    showPicker = true
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.accent)
                        Text("Choose a photo")
                            .font(.headline)
                        Text("It becomes a black-and-white colouring page.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 190)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
            }
        }
    }

    // MARK: actions

    private var actionSection: some View {
        VStack(spacing: 10) {
            if model.isRunning {
                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    model.generate()
                } label: {
                    Text(model.output == nil ? "Generate page" : "Generate again")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.photo == nil)

                if let output = model.output, output.item != nil {
                    Button {
                        showResult = true
                    } label: {
                        Label("Show page", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }

    // MARK: progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.stage?.label(progress: model.stageFraction) ?? "Working…")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                elapsed
            }
            ProgressView(value: min(max(model.overallProgress, 0), 1))
                .tint(Theme.accent)
            if model.settings.engine == .localServer {
                Text("Rendering on desktop2. The first page after a server restart "
                     + "can take a minute while the model loads.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var elapsed: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Text(elapsedText(now: context.date))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func elapsedText(now: Date) -> String {
        guard let startedAt = model.startedAt else { return "" }
        let seconds = max(0, now.timeIntervalSince(startedAt))
        return String(format: "%.0f s", seconds)
    }

    // MARK: error

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            HStack {
                if model.photo != nil {
                    Button("Retry") { model.retry() }
                        .buttonStyle(.borderedProminent)
                }
                Button(model.alternateEngine == .localServer
                       ? "Use Local server" : "Use On-device") {
                    model.switchEngineAndRetry()
                }
                .buttonStyle(.bordered)
                Button("Settings") { showSettings = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.versionLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let health = model.health, !health.ok, let detail = health.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
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
