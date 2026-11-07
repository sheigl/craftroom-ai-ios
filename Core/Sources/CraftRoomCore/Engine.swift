import Foundation

/// Which backend performs one photo -> colouring page conversion (v0.6 dual
/// backend, plan `.opencode/plan/v06-dual-backend.md`).
///
/// The on-device path is the existing Core ML pipeline; the local-server path
/// talks to the FastAPI/ComfyUI service on desktop2. The raw values are the
/// persisted identity (`UserDefaults`) and the `engine` stamp in metadata, so
/// they must stay stable.
public enum EngineID: String, Codable, CaseIterable, Sendable {
    case onDevice = "on_device"
    case localServer = "local_server"

    public var label: String {
        switch self {
        case .onDevice: return "On-device"
        case .localServer: return "Local server"
        }
    }

    public var detail: String {
        switch self {
        case .onDevice:
            return "Core ML on this iPad — needs the downloaded models"
        case .localServer:
            return "ComfyUI on desktop2 over Wi-Fi — needs no download"
        }
    }

    public var isRemote: Bool { self == .localServer }
}

/// One user-visible phase of a conversion.
///
/// The raw values are the server's stage strings where they exist (`queued`,
/// `preparing`, `generating`, `postprocessing`, `done`, `failed`); `uploading`
/// is the app's own photo upload and maps onto no server stage. Labels are what
/// the progress card shows, and are shared by both backends so the flow reads
/// the same on-device and remote.
public enum Stage: String, Codable, CaseIterable, Sendable {
    case uploading
    case queued
    case preparing
    case rendering
    case finishing
    case done
    case failed

    /// Maps a server stage string onto a `Stage`.
    ///
    /// `uploading` on the server means "edge map -> ComfyUI" (milliseconds), so
    /// it is folded into `preparing`; an unknown value is treated as queued
    /// rather than guessed.
    public static func from(server raw: String?) -> Stage {
        switch (raw ?? "").lowercased() {
        case "queued": return .queued
        case "preparing": return .preparing
        case "uploading": return .preparing
        case "generating", "running": return .rendering
        case "postprocessing": return .finishing
        case "done": return .done
        case "failed": return .failed
        default: return .queued
        }
    }

    public var isTerminal: Bool { self == .done || self == .failed }

    /// The plain label (used before the first progress report).
    public var label: String { label(progress: nil) }

    /// The progress card line: `Drawing lines 41 %` while rendering.
    public func label(progress: Double?) -> String {
        switch self {
        case .uploading: return "Uploading photo"
        case .queued: return "Queued on desktop2"
        case .preparing: return "Tracing edges"
        case .rendering:
            guard let progress, progress > 0 else { return "Drawing lines" }
            return "Drawing lines \(Int((progress * 100).rounded())) %"
        case .finishing: return "Finishing"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    /// Overall completion of one conversion (0…1), so the bar moves smoothly
    /// across phase boundaries and never jumps backwards.
    public func overallProgress(_ fraction: Double?) -> Double {
        let f = max(0, min(1, fraction ?? 0))
        switch self {
        case .uploading: return 0.02 + 0.02 * f
        case .queued: return 0.05
        case .preparing: return 0.06 + 0.08 * f
        case .rendering: return 0.15 + 0.79 * f
        case .finishing: return 0.95 + 0.05 * f
        case .done: return 1
        case .failed: return f
        }
    }
}

/// What a caller asks an engine to convert.
///
/// `photo` is the encoded source (the app sends JPEG); the engine never sees
/// `UIImage`, which is what keeps this type testable on Linux.
public struct GenerationInput: Equatable, Sendable {
    public var photo: Data
    /// Server `aspect` field: `auto`, `square`, `portrait`, `landscape` or
    /// `W:H`. The source photo's own aspect always drives the output crop.
    public var aspect: String
    public var seed: UInt64?
    public var filename: String
    public var contentType: String

    public init(photo: Data, aspect: String = "auto", seed: UInt64? = nil,
                filename: String = "photo.jpg", contentType: String = "image/jpeg") {
        self.photo = photo
        self.aspect = aspect
        self.seed = seed
        self.filename = filename
        self.contentType = contentType
    }
}

/// Everything a saved page needs to describe where it came from.
public struct PageMetadata: Codable, Equatable, Sendable {
    public var engine: String
    public var model: String?
    public var seed: Int?
    public var steps: Int?
    public var cfg: Double?
    public var width: Int?
    public var height: Int?
    public var jobID: String?
    public var recipe: String?
    public var timings: [String: Double]

    public init(engine: EngineID, model: String? = nil, seed: Int? = nil,
                steps: Int? = nil, cfg: Double? = nil, width: Int? = nil,
                height: Int? = nil, jobID: String? = nil, recipe: String? = nil,
                timings: [String: Double] = [:]) {
        self.engine = engine.rawValue
        self.model = model
        self.seed = seed
        self.steps = steps
        self.cfg = cfg
        self.width = width
        self.height = height
        self.jobID = jobID
        self.recipe = recipe
        self.timings = timings
    }
}

/// One finished page, engine-independent.
public struct PageResult: Equatable, Sendable {
    /// PNG bytes — the page as it will be saved and shared.
    public var png: Data
    public var width: Int
    public var height: Int
    public var metadata: PageMetadata
    /// Wall-clock time of the whole conversion (including upload and polling).
    public var elapsed: Double

    public init(png: Data, width: Int, height: Int, metadata: PageMetadata,
                elapsed: Double) {
        self.png = png
        self.width = width
        self.height = height
        self.metadata = metadata
        self.elapsed = elapsed
    }
}

/// One connection test / engine state, persisted so Settings can show the last
/// answer without another round trip.
public struct EngineHealth: Codable, Equatable, Sendable {
    public var ok: Bool
    public var engine: EngineID
    public var baseURL: String?
    public var summary: String
    public var detail: String?
    public var serverVersion: String?
    public var comfyVersion: String?
    public var modelID: String?
    public var modelSHA256: String?
    public var queue: String?
    public var vramFreeMB: Double?
    public var vramTotalMB: Double?
    public var checkedAt: Date?

    public init(ok: Bool, engine: EngineID, baseURL: String? = nil,
                summary: String, detail: String? = nil,
                serverVersion: String? = nil, comfyVersion: String? = nil,
                modelID: String? = nil, modelSHA256: String? = nil,
                queue: String? = nil, vramFreeMB: Double? = nil,
                vramTotalMB: Double? = nil, checkedAt: Date? = nil) {
        self.ok = ok
        self.engine = engine
        self.baseURL = baseURL
        self.summary = summary
        self.detail = detail
        self.serverVersion = serverVersion
        self.comfyVersion = comfyVersion
        self.modelID = modelID
        self.modelSHA256 = modelSHA256
        self.queue = queue
        self.vramFreeMB = vramFreeMB
        self.vramTotalMB = vramTotalMB
        self.checkedAt = checkedAt
    }

    /// Short form for the Settings health row (`c7963a72…`).
    public var modelSHAShort: String? {
        guard let modelSHA256, !modelSHA256.isEmpty else { return nil }
        return String(modelSHA256.prefix(12)) + "…"
    }
}

/// Structured engine failures. The descriptions are the product's error copy:
/// each one says what the owner can do next, because the iPad has no console
/// and a dead desktop2 must not look like a broken app.
public enum EngineError: Error, Equatable, LocalizedError {
    /// The typed URL cannot be a server base (`http`/`https` + host).
    case invalidURL(String)
    /// The host is down, off the network, or the request never completed.
    case unreachable(base: String, detail: String)
    /// The server answered with a structured error body.
    case server(status: Int, code: String, message: String)
    /// The job reached `failed` (the error block of `/jobs/{id}`).
    case jobFailed(code: String, message: String)
    /// The job did not finish inside the policy's total timeout.
    case timedOut(seconds: Double)
    /// The worker picked this job up but the server cannot answer right now.
    case cancelled
    /// A response that does not decode (server changed, wrong host, HTML page).
    case badResponse(String)
    /// On-device only: the Core ML payload is not installed.
    case payloadMissing
    /// The source photo could not be read.
    case invalidPhoto(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "“\(raw)” is not a server address. Type something like "
                + "http://192.168.68.92:8124"
        case .unreachable(let base, let detail):
            return "Can't reach \(base). Check that desktop2 is on and this iPad "
                + "is on the same Wi-Fi, then tap Test connection. (\(detail))"
        case .server(_, let code, let message):
            switch code {
            case "comfyui_unavailable":
                return "The server is running, but ComfyUI on desktop2 is not. "
                    + "Start ComfyUI on desktop2, then retry."
            case "vram_low":
                return "desktop2's GPU is busy (another job holds the memory). "
                    + "Wait a minute and retry."
            case "queue_full":
                return "The server is busy with other jobs. Retry in a moment."
            case "model_unavailable":
                return "The server can't find the frozen model. Deploy it on "
                    + "desktop2 with sdxl/api/deploy.sh, then retry."
            case "invalid_input":
                return "The server rejected this photo: \(message)"
            case "unknown_job":
                return "The server lost track of this job (it may have restarted). "
                    + "Generate again."
            case "not_found", "http_404":
                return "There is no Craft Room server at that address. Check the "
                    + "URL and port (8124), then retry."
            default:
                return "Server error \(code): \(message)"
            }
        case .jobFailed(let code, let message):
            return "The conversion failed on desktop2 (\(code)): \(message)"
        case .timedOut(let seconds):
            return "The conversion did not finish within "
                + "\(Int(seconds / 60)) minutes. Check the server on desktop2, "
                + "then retry."
        case .cancelled:
            return "Cancelled."
        case .badResponse(let detail):
            return "The server answered with something this app does not "
                + "understand. Is the URL really the Craft Room server? (\(detail))"
        case .payloadMissing:
            return "The on-device models are not installed yet. Switch to Local "
                + "server in Settings, or download the models there."
        case .invalidPhoto(let detail):
            return "This photo could not be read: \(detail)"
        }
    }

    /// Whether the operation is worth retrying without user action (transient
    /// server load / GPU pressure).
    public var isTransient: Bool {
        switch self {
        case .server(_, let code, _):
            return RetryPolicy.retryable(code: code)
        case .unreachable, .timedOut:
            return true
        default:
            return false
        }
    }
}

/// The backend contract (plan T3): both engines return the same `PageResult`
/// and report the same stages, so the product flow is engine-agnostic.
public protocol GenerationEngine {
    var id: EngineID { get }
    /// Connection/availability check for Settings and the pre-flight of a run.
    func health() async throws -> EngineHealth
    /// Convert one photo. `progress` is called with monotonically advancing
    /// overall positions; the final call is `(.done, 1)`.
    func generate(_ input: GenerationInput,
                  progress: @escaping (Stage, Double) -> Void) async throws -> PageResult
}

/// Default-selection policy (plan T3.4).
///
/// A saved choice always wins — switching engines must survive launches. Only
/// a first launch decides: payload installed -> on-device, otherwise the local
/// server at the default LAN URL. Remote mode therefore never needs the
/// 7.6 GB download.
public enum EngineSelection {
    public static func initialEngine(payloadInstalled: Bool) -> EngineID {
        payloadInstalled ? .onDevice : .localServer
    }

    public static func resolve(saved: EngineID?, payloadInstalled: Bool) -> EngineID {
        saved ?? initialEngine(payloadInstalled: payloadInstalled)
    }

    public static func initialBaseURL(saved: URL?) -> URL {
        saved ?? ServerURL.default
    }
}

/// The server's `aspect` field, validated the same way the service does
/// (`sdxl/api/validation.py`), plus the label the app derives from a photo.
public enum AspectRequest {
    public static let auto = "auto"

    private static let words: Set<String> = [
        "auto", "source", "original", "square", "portrait", "landscape",
    ]

    /// Normalises a user/picker value to a token the server accepts, or nil.
    public static func normalise(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= 32 else { return nil }
        if words.contains(text) { return text }
        let separators = CharacterSet(charactersIn: ":x/")
        let sides = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard sides.count == 2,
              let w = Int(sides[0]), let h = Int(sides[1]),
              (1...64).contains(w), (1...64).contains(h) else { return nil }
        let ratio = Double(w) / Double(h)
        guard (0.2...5.0).contains(ratio) else { return nil }
        return "\(w):\(h)"
    }

    /// The token the app sends for a photo: square / portrait / landscape.
    /// (The server still crops to the source's true aspect; this only states
    /// what was requested, so it never reports a mismatch.)
    public static func label(forWidth width: Int, height: Int,
                             tolerance: Double = 0.02) -> String {
        guard width > 0, height > 0 else { return auto }
        let ratio = Double(width) / Double(height)
        if abs(ratio - 1) <= tolerance { return "square" }
        return ratio > 1 ? "landscape" : "portrait"
    }
}
