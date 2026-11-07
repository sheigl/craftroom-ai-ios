import Foundation

/// Minimal HTTP types so the remote client can live in `CraftRoomCore` — and
/// therefore be unit-tested on Linux against a fake transport — while the app
/// supplies a `URLSession` implementation.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL,
                headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

// MARK: - JSON decoding

/// The service's structured error body: `{"error":{"code","message","detail"}}`.
public struct ApiErrorBody: Equatable, Sendable {
    public var code: String
    public var message: String
    public var detail: String?

    public init(code: String, message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    public static func decode(_ data: Data) -> ApiErrorBody? {
        guard let root = jsonObject(data) else { return nil }
        guard let error = root["error"] as? [String: Any] else { return nil }
        guard let code = string(error["code"]) else { return nil }
        return ApiErrorBody(code: code,
                            message: string(error["message"]) ?? code,
                            detail: detailText(error["detail"]))
    }
}

/// The 202 answer of `POST /generate`.
public struct AcceptedJob: Equatable, Sendable {
    public var jobID: String
    public var state: String
    public var stage: Stage
    public var queuePosition: Int?

    public init(jobID: String, state: String, stage: Stage, queuePosition: Int? = nil) {
        self.jobID = jobID
        self.state = state
        self.stage = stage
        self.queuePosition = queuePosition
    }

    public static func decode(_ data: Data) -> AcceptedJob? {
        guard let root = jsonObject(data),
              let jobID = string(root["job_id"]) else { return nil }
        let state = string(root["state"]) ?? "queued"
        let stage = Stage.from(server: string(root["stage"]))
        return AcceptedJob(jobID: jobID, state: state, stage: stage,
                           queuePosition: int(root["queue_position"]))
    }
}

/// A job-level failure as the server reports it (`error` of `/jobs/{id}`).
public struct JobFailure: Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Where the finished artefacts live, as echoed by the job status.
public struct JobResultInfo: Equatable, Sendable {
    public var width: Int?
    public var height: Int?

    public init(width: Int? = nil, height: Int? = nil) {
        self.width = width
        self.height = height
    }
}

/// One `GET /jobs/{id}` snapshot. Decoding is deliberately tolerant: a field
/// that is missing or of an unexpected type must not fail a run, because the
/// stage/state pair is all the flow needs.
public struct JobStatus: Equatable, Sendable {
    public var jobID: String
    public var state: String
    public var stage: Stage
    public var progress: Double
    public var failure: JobFailure?
    public var queuePosition: Int?
    public var timings: [String: Double]
    public var result: JobResultInfo?
    public var modelID: String?
    public var seed: Int?
    public var steps: Int?
    public var cfg: Double?
    public var recipe: String?

    public init(jobID: String, state: String, stage: Stage,
                progress: Double = 0, failure: JobFailure? = nil,
                queuePosition: Int? = nil, timings: [String: Double] = [:],
                result: JobResultInfo? = nil, modelID: String? = nil,
                seed: Int? = nil, steps: Int? = nil, cfg: Double? = nil,
                recipe: String? = nil) {
        self.jobID = jobID
        self.state = state
        self.stage = stage
        self.progress = progress
        self.failure = failure
        self.queuePosition = queuePosition
        self.timings = timings
        self.result = result
        self.modelID = modelID
        self.seed = seed
        self.steps = steps
        self.cfg = cfg
        self.recipe = recipe
    }

    public var isDone: Bool { state == "done" }
    public var isFailed: Bool { state == "failed" }

    public static func decode(_ data: Data) -> JobStatus? {
        guard let root = jsonObject(data) else { return nil }
        let state = string(root["state"]) ?? ""
        // A body without a state is not a job snapshot (an HTML error page, a
        // proxy notice); refusing it keeps "queued" from being invented.
        guard !state.isEmpty else { return nil }
        let jobID = string(root["job_id"]) ?? ""
        let settings = root["settings"] as? [String: Any]
        let resultDict = root["result"] as? [String: Any]
        let errorDict = root["error"] as? [String: Any]
        let failure: JobFailure?
        if let errorDict, let code = string(errorDict["code"]) {
            failure = JobFailure(code: code,
                                 message: string(errorDict["message"]) ?? code)
        } else {
            failure = nil
        }
        var timings: [String: Double] = [:]
        if let raw = root["timings"] as? [String: Any] {
            for (key, value) in raw {
                if let d = double(value) { timings[key] = d }
            }
        }
        return JobStatus(
            jobID: jobID,
            state: state,
            stage: Stage.from(server: string(root["stage"])),
            progress: max(0, min(1, double(root["progress"]) ?? 0)),
            failure: failure,
            queuePosition: int(root["queue_position"]),
            timings: timings,
            result: resultDict.map {
                JobResultInfo(width: int($0["width"]), height: int($0["height"]))
            },
            modelID: string(settings?["model_id"]),
            seed: int(settings?["seed"]),
            steps: int(settings?["steps"]),
            cfg: double(settings?["cfg"]),
            recipe: string(settings?["recipe"]))
    }
}

/// `GET /health`, flattened enough for the Settings row.
public struct ServerHealth: Equatable, Sendable {
    public var ok: Bool
    public var serverVersion: String?
    public var comfyOK: Bool
    public var comfyVersion: String?
    public var device: String?
    public var modelID: String?
    public var modelSHA256: String?
    public var modelOK: Bool
    public var queueQueued: Int?
    public var queueMax: Int?
    public var vramFreeBytes: Int64?
    public var vramTotalBytes: Int64?
    public var problem: String?

    public init(ok: Bool, serverVersion: String? = nil, comfyOK: Bool = false,
                comfyVersion: String? = nil, device: String? = nil,
                modelID: String? = nil, modelSHA256: String? = nil,
                modelOK: Bool = false, queueQueued: Int? = nil,
                queueMax: Int? = nil, vramFreeBytes: Int64? = nil,
                vramTotalBytes: Int64? = nil, problem: String? = nil) {
        self.ok = ok
        self.serverVersion = serverVersion
        self.comfyOK = comfyOK
        self.comfyVersion = comfyVersion
        self.device = device
        self.modelID = modelID
        self.modelSHA256 = modelSHA256
        self.modelOK = modelOK
        self.queueQueued = queueQueued
        self.queueMax = queueMax
        self.vramFreeBytes = vramFreeBytes
        self.vramTotalBytes = vramTotalBytes
        self.problem = problem
    }

    public static func decode(_ data: Data) -> ServerHealth? {
        guard let root = jsonObject(data) else { return nil }
        let comfy = root["comfyui"] as? [String: Any]
        let model = root["model"] as? [String: Any]
        let queue = root["queue"] as? [String: Any]
        let comfyOK = bool(comfy?["ok"]) ?? false
        let modelOK = bool(model?["ok"]) ?? false
        let ok = bool(root["ok"]) ?? (comfyOK && modelOK)
        var problem: String?
        if let comfy, !comfyOK { problem = string(comfy["error"]) ?? "ComfyUI is not reachable" }
        if problem == nil, let model, !modelOK {
            problem = string(model["error"]) ?? "the pinned student is not available"
        }
        return ServerHealth(
            ok: ok,
            serverVersion: string(root["version"]),
            comfyOK: comfyOK,
            comfyVersion: string(comfy?["version"]),
            device: string(comfy?["device"]),
            modelID: string(model?["id"]),
            modelSHA256: string(model?["sha256"]),
            modelOK: modelOK,
            queueQueued: int(queue?["queued"]),
            queueMax: int(queue?["max"]),
            vramFreeBytes: int64(comfy?["vram_free_bytes"]),
            vramTotalBytes: int64(comfy?["vram_total_bytes"]),
            problem: problem)
    }

    /// The Settings health row.
    public func engineHealth(baseURL: URL, checkedAt: Date = Date()) -> EngineHealth {
        var parts: [String] = []
        if let serverVersion { parts.append("API \(serverVersion)") }
        if let comfyVersion { parts.append("ComfyUI \(comfyVersion)") }
        if let modelID { parts.append(modelID) }
        if let queueQueued, let queueMax {
            parts.append(queueQueued == 0 ? "queue idle" : "\(queueQueued)/\(queueMax) queued")
        }
        if let vramFreeBytes, let vramTotalBytes, vramTotalBytes > 0 {
            parts.append(String(format: "%.1f/%.0f GB VRAM free",
                                Double(vramFreeBytes) / 1e9,
                                Double(vramTotalBytes) / 1e9))
        }
        let summary = parts.isEmpty ? (ok ? "Server ready" : "Server not ready")
                                    : parts.joined(separator: " · ")
        return EngineHealth(
            ok: ok,
            engine: .localServer,
            baseURL: baseURL.absoluteString,
            summary: summary,
            detail: problem,
            serverVersion: serverVersion,
            comfyVersion: comfyVersion,
            modelID: modelID,
            modelSHA256: modelSHA256,
            queue: queueQueued.map { queued in
                guard let queueMax else { return "\(queued) queued" }
                return "\(queued)/\(queueMax) queued"
            },
            vramFreeMB: vramFreeBytes.map { Double($0) / 1_048_576 },
            vramTotalMB: vramTotalBytes.map { Double($0) / 1_048_576 },
            checkedAt: checkedAt)
    }
}

/// The parts of `GET /jobs/{id}/result.json` the app keeps.
public struct ResultMetadata: Equatable, Sendable {
    public var modelID: String?
    public var modelSHA256: String?
    public var seed: Int?
    public var steps: Int?
    public var cfg: Double?
    public var recipe: String?
    public var width: Int?
    public var height: Int?
    public var timings: [String: Double]

    public init(modelID: String? = nil, modelSHA256: String? = nil,
                seed: Int? = nil, steps: Int? = nil, cfg: Double? = nil,
                recipe: String? = nil, width: Int? = nil, height: Int? = nil,
                timings: [String: Double] = [:]) {
        self.modelID = modelID
        self.modelSHA256 = modelSHA256
        self.seed = seed
        self.steps = steps
        self.cfg = cfg
        self.recipe = recipe
        self.width = width
        self.height = height
        self.timings = timings
    }

    public static func decode(_ data: Data) -> ResultMetadata? {
        guard let root = jsonObject(data) else { return nil }
        let model = root["model"] as? [String: Any]
        let settings = root["settings"] as? [String: Any]
        let output = root["output"] as? [String: Any]
        var timings: [String: Double] = [:]
        if let raw = root["timings"] as? [String: Any] {
            for (key, value) in raw {
                if let d = double(value) { timings[key] = d }
            }
        }
        return ResultMetadata(
            modelID: string(model?["id"]),
            modelSHA256: string(model?["sha256"]),
            seed: int(settings?["seed"]),
            steps: int(settings?["steps"]),
            cfg: double(settings?["cfg"]),
            recipe: string(settings?["recipe"]),
            width: int(output?["width"]),
            height: int(output?["height"]),
            timings: timings)
    }
}

/// PNG dimensions straight from the IHDR chunk — no image framework needed, so
/// `CraftRoomCore` stays platform-independent and a malformed PNG is caught
/// before it reaches the gallery.
public enum PNGHeader {
    public static func size(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24,
              bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
              bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52
        else { return nil }
        func be32(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        let w = be32(16), h = be32(20)
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }
}

// MARK: - tolerant JSON helpers

/// `JSONSerialization` (not `Codable`) on purpose: the service may add fields
/// and the app must ignore them; a missing or re-typed field must not fail a
/// run mid-poll.
func jsonObject(_ data: Data) -> [String: Any]? {
    guard !data.isEmpty,
          let any = try? JSONSerialization.jsonObject(with: data),
          let dict = any as? [String: Any] else { return nil }
    return dict
}

func string(_ value: Any?) -> String? {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
}

func int(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String { return Int(s) }
    return nil
}

func int64(_ value: Any?) -> Int64? {
    if let n = value as? NSNumber { return n.int64Value }
    if let s = value as? String { return Int64(s) }
    return nil
}

func double(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

func bool(_ value: Any?) -> Bool? {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    return nil
}

/// `detail` is a string or a free-form object in the API; keep one readable
/// line either way (it goes into logs and error copy, never parsed again).
func detailText(_ value: Any?) -> String? {
    if let s = value as? String { return s }
    guard let value, !(value is NSNull) else { return nil }
    if let dict = value as? [String: Any],
       let data = try? JSONSerialization.data(withJSONObject: dict,
                                              options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        return text
    }
    if let array = value as? [Any],
       let data = try? JSONSerialization.data(withJSONObject: array),
       let text = String(data: data, encoding: .utf8) {
        return text
    }
    return nil
}
