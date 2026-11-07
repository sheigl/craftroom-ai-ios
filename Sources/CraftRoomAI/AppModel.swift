import Foundation
import UIKit
import CraftRoomCore

/// One finished run, kept in memory for the result view: the page, where it was
/// saved, and the source photo for the before/after slider.
struct GenerationOutput: Identifiable {
    let id = UUID()
    let page: PageResult
    let item: RenderItem?
    let source: UIImage?

    var pageImage: UIImage? { UIImage(data: page.png) }
}

/// The product flow's state machine (plan T4.7–T4.10): photo, engine choice,
/// generation with honest stages, result, gallery, developer settings.
///
/// Engines are built per run, so switching backend needs no restart and an
/// unreachable desktop2 leaves the app idle and switchable instead of stuck.
@MainActor
final class AppModel: ObservableObject {
    // MARK: persisted settings

    @Published var settings: EngineSettings {
        didSet { EngineSettingsStore.save(settings, to: defaults) }
    }

    // MARK: flow state

    @Published private(set) var photo: UIImage?
    @Published private(set) var isRunning = false
    @Published private(set) var stage: Stage?
    @Published private(set) var stageFraction: Double = 0
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var status = "Pick a photo to begin."
    @Published private(set) var errorMessage: String?
    @Published private(set) var output: GenerationOutput?

    // MARK: payload / health / gallery

    @Published private(set) var payloadState: PayloadState = .checking
    @Published private(set) var health: EngineHealth?
    @Published private(set) var testingConnection = false
    @Published private(set) var isDownloadingPayload = false
    @Published private(set) var galleryToken = 0

    private let engine: Engine
    private let defaults: UserDefaults
    private var runTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var lastInput: GenerationInput?

    init(engine: Engine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        let installed = PayloadStore.shared.isReady
        self.settings = EngineSettingsStore.load(from: defaults,
                                                payloadInstalled: installed)
        self.payloadState = PayloadStore.shared.state
        self.health = settings.lastHealth
    }

    // MARK: lifecycle

    func onAppear() {
        payloadState = PayloadStore.shared.state
        health = settings.lastHealth
        if settings.engine == .onDevice && !PayloadStore.shared.isReady {
            status = "On-device models are not installed — switch to Local server "
                + "in Settings, or download them there."
        }
    }

    var versionLine: String {
        "\(Diagnostics.build) · \(settings.engine.label) · \(Diagnostics.machine)"
    }

    var alternateEngine: EngineID {
        settings.engine == .onDevice ? .localServer : .onDevice
    }

    // MARK: photo

    func setPhoto(_ image: UIImage) {
        photo = image
        output = nil
        errorMessage = nil
        stage = nil
        status = "Photo ready. Tap Generate."
    }

    func clearPhoto() {
        guard !isRunning else { return }
        photo = nil
        output = nil
        errorMessage = nil
        status = "Pick a photo to begin."
    }

    // MARK: settings

    func setEngine(_ id: EngineID) {
        guard settings.engine != id else { return }
        settings.engine = id
        errorMessage = nil
        health = settings.lastHealth
        status = id == .localServer
            ? "Local server: \(settings.baseURL.absoluteString)"
            : "On-device: \(PayloadStore.shared.isReady ? "models installed" : "models not downloaded")"
    }

    /// Validates and stores a typed server URL; returns a problem string or nil.
    @discardableResult
    func applyBaseURL(_ text: String) -> String? {
        do {
            let url = try ServerURL.parse(text)
            settings.baseURL = url
            health = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setSeed(_ seed: UInt64?) {
        settings.seed = seed
    }

    var seedText: String {
        settings.seed.map(String.init) ?? ""
    }

    func setHealth(_ value: EngineHealth?) {
        health = value
        if let value {
            settings.lastHealth = value
        }
    }

    // MARK: generation

    func generate(seed: UInt64? = nil) {
        guard !isRunning, let photo else { return }
        guard let data = photo.jpegData(compressionQuality: 0.92) else {
            errorMessage = "This photo could not be prepared for generation."
            return
        }
        let input = GenerationInput(
            photo: data,
            aspect: AspectRequest.label(forWidth: Int(photo.size.width.rounded()),
                                        height: Int(photo.size.height.rounded())),
            seed: seed ?? settings.seed)
        lastInput = input

        let engine: GenerationEngine
        do {
            engine = try makeEngine()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        isRunning = true
        errorMessage = nil
        output = nil
        startedAt = Date()
        stage = .uploading
        stageFraction = 0
        overallProgress = Stage.uploading.overallProgress(0)
        status = Stage.uploading.label
        UIApplication.shared.isIdleTimerDisabled = true

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.generate(input) { stage, fraction in
                    Task { @MainActor [weak self] in
                        self?.apply(stage: stage, fraction: fraction)
                    }
                }
                self.finish(result: result)
            } catch is CancellationError {
                self.finishCancelled()
            } catch {
                self.finishFailure(error)
            }
        }
    }

    /// Same photo, same settings, a fresh seed — a genuine second attempt.
    func regenerate() {
        guard !isRunning, photo != nil else { return }
        let seed = UInt64.random(in: 0...UInt64(Int32.max))
        generate(seed: seed)
    }

    func retry() {
        generate(seed: lastInput?.seed)
    }

    func switchEngineAndRetry() {
        setEngine(alternateEngine)
        generate(seed: lastInput?.seed)
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    private func apply(stage: Stage, fraction: Double) {
        self.stage = stage
        self.stageFraction = fraction
        let value = stage.overallProgress(fraction)
        overallProgress = max(overallProgress, value)
        status = stage.label(progress: fraction)
    }

    private func finish(result: PageResult) {
        isRunning = false
        runTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        stage = .done
        stageFraction = 1
        overallProgress = 1
        status = String(format: "Page ready in %.1f s", result.elapsed)
        do {
            let item = try RenderStore.save(page: result, sourcePhoto: photo)
            output = GenerationOutput(page: result, item: item, source: photo)
            galleryToken += 1
            Diagnostics.log("render saved \(item.pageURL.lastPathComponent)")
        } catch {
            errorMessage = "The page was generated but could not be saved: "
                + error.localizedDescription
            output = GenerationOutput(page: result, item: nil, source: photo)
        }
    }

    private func finishCancelled() {
        isRunning = false
        runTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        stage = nil
        overallProgress = 0
        status = "Cancelled."
    }

    private func finishFailure(_ error: Error) {
        isRunning = false
        runTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        stage = nil
        overallProgress = 0
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        errorMessage = message
        status = "Failed"
        Diagnostics.log("generate failed: \(message)")
    }

    private func makeEngine() throws -> GenerationEngine {
        switch settings.engine {
        case .onDevice:
            return OnDeviceEngine(engine: engine)
        case .localServer:
            return RemoteEngine(baseURL: settings.baseURL,
                                transport: URLSessionTransport(),
                                log: { Diagnostics.log($0) })
        }
    }

    // MARK: health

    func testConnection() async {
        guard !testingConnection else { return }
        testingConnection = true
        defer { testingConnection = false }
        let engineID = settings.engine
        do {
            let engine = try makeEngine()
            let result = try await engine.health()
            setHealth(result)
            status = result.summary
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            setHealth(EngineHealth(
                ok: false,
                engine: engineID,
                baseURL: engineID == .localServer ? settings.baseURL.absoluteString : nil,
                summary: engineID == .localServer ? "Server not reachable"
                                                  : "On-device models not ready",
                detail: message,
                checkedAt: Date()))
            status = message
        }
    }

    // MARK: payload (on-device models)

    func refreshPayload() {
        payloadState = PayloadStore.shared.state
    }

    func downloadModels() {
        guard !isDownloadingPayload else { return }
        let store = PayloadStore.shared
        let variant = AttentionVariant(rawValue: store.variant) ?? .sdpa
        let totalMB = (store.manifestV2
            .flatMap { try? $0.bytes(forVariant: variant.rawValue) } ?? 0) / 1_048_576
        isDownloadingPayload = true
        payloadState = .downloading(fraction: 0, doneMB: 0, totalMB: totalMB)
        status = "Downloading models…"
        Telemetry.send("payload: download start, base \(store.baseURL) "
                       + "variant \(variant.rawValue) (~\(totalMB / 1024) GB)")

        downloadTask = Task { [weak self] in
            guard let self else { return }
            let poll = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    let snapshot = store.snapshot()
                    await MainActor.run { [weak self] in
                        self?.payloadState = .downloading(
                            fraction: Double(snapshot.done) / Double(max(snapshot.total, 1)),
                            doneMB: snapshot.done / 1_048_576,
                            totalMB: snapshot.total / 1_048_576)
                    }
                }
            }
            do {
                try await store.downloadAll()
                poll.cancel()
                self.isDownloadingPayload = false
                self.payloadState = .ready
                self.status = "Models installed."
                Telemetry.send("payload: installed \(variant.rawValue)")
            } catch {
                poll.cancel()
                let message = error.localizedDescription
                self.isDownloadingPayload = false
                self.payloadState = .failed(message)
                self.status = "Download failed."
                Diagnostics.log("payload download failed: \(message)")
                Telemetry.send("payload download failed: \(message)")
            }
        }
    }

    func cancelModelDownload() {
        PayloadStore.shared.cancel()
    }

    // MARK: gallery

    func delete(_ item: RenderItem) {
        RenderStore.delete(item)
        galleryToken += 1
    }

    func clearSavedOutput() {
        output = nil
    }
}
