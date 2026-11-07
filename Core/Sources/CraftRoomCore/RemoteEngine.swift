import Foundation

/// The local-server engine (plan T3.3): uploads the photo, polls the job,
/// downloads the page.
///
/// The transport is injected (`HTTPTransport`) so this class is testable on
/// Linux with a fake, and the sleep is injected so the retry/backoff timeline
/// can be asserted without waiting. Behaviour against the real service:
///
///  * `POST /generate` multipart (`photo`, `aspect`, optional `seed`) -> 202
///    `{job_id}`; `503` is retried with exponential backoff (2, 4, 8, 16, 30 s
///    cap) because `queue_full` / `vram_low` / `comfyui_unavailable` are normal
///    states of a one-job server on a shared GPU;
///  * `GET /jobs/{id}` every ~700 ms (±25 % jitter) until `done`/`failed`;
///  * `GET /jobs/{id}/result.png` then `result.json`;
///  * the whole operation is bounded by `policy.totalTimeout` (10 min), so an
///    unreachable desktop2 produces a clear error instead of a spinner;
///  * cancelling the enclosing `Task` stops the polling and throws
///    `CancellationError` (the server finishes the job on its own — there is no
///    server-side cancel endpoint).
public final class RemoteEngine: GenerationEngine {
    public typealias SleepFn = (TimeInterval) async throws -> Void

    public let id: EngineID = .localServer
    public let baseURL: URL
    private let transport: HTTPTransport
    private let policy: RetryPolicy
    private let sleep: SleepFn
    private let log: (String) -> Void

    public init(baseURL: URL, transport: HTTPTransport,
                policy: RetryPolicy = .default,
                sleep: @escaping SleepFn = RemoteEngine.defaultSleep,
                log: @escaping (String) -> Void = { _ in }) {
        self.baseURL = baseURL
        self.transport = transport
        self.policy = policy
        self.sleep = sleep
        self.log = log
    }

    public static let defaultSleep: SleepFn = { seconds in
        guard seconds > 0 else { return }
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }

    // MARK: - health

    public func health() async throws -> EngineHealth {
        let request = HTTPRequest(method: "GET",
                                  url: ServerURL.endpoint(baseURL, "health"),
                                  headers: ["Accept": "application/json"])
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw EngineError.cancelled
        } catch {
            throw EngineError.unreachable(base: baseURL.absoluteString,
                                          detail: error.localizedDescription)
        }
        guard response.status == 200 else {
            if let api = ApiErrorBody.decode(response.body) {
                return EngineHealth(ok: false, engine: .localServer,
                                    baseURL: baseURL.absoluteString,
                                    summary: "Server returned \(response.status)",
                                    detail: api.message, checkedAt: Date())
            }
            throw Self.error(status: response.status, body: response.body)
        }
        guard let health = ServerHealth.decode(response.body) else {
            throw EngineError.badResponse("/health is not the Craft Room API answer")
        }
        return health.engineHealth(baseURL: baseURL)
    }

    // MARK: - generate

    public func generate(_ input: GenerationInput,
                         progress: @escaping (Stage, Double) -> Void) async throws -> PageResult {
        let started = Date()
        var budget = Budget(limit: policy.totalTimeout)
        guard !input.photo.isEmpty else {
            throw EngineError.invalidPhoto("no photo data")
        }
        progress(.uploading, 0.02)
        log("remote: POST \(ServerURL.endpoint(baseURL, "generate")) "
            + "(\(input.photo.count / 1024) KB, aspect \(input.aspect))")

        let accepted = try await submit(input, budget: &budget, progress: progress)
        log("remote: job \(accepted.jobID) accepted (\(accepted.state))")
        progress(accepted.stage, 0)

        let status = try await waitForCompletion(jobID: accepted.jobID,
                                                 budget: &budget, progress: progress)
        let (png, metadata) = try await fetchResult(jobID: accepted.jobID, status: status,
                                                    input: input, budget: &budget)
        progress(.done, 1)

        let size = PNGHeader.size(png)
        let width = metadata.width ?? status.result?.width ?? size?.width ?? 0
        let height = metadata.height ?? status.result?.height ?? size?.height ?? 0
        let result = PageResult(png: png, width: width, height: height,
                                metadata: metadata,
                                elapsed: Date().timeIntervalSince(started))
        log("remote: job \(accepted.jobID) done, \(png.count / 1024) KB PNG, "
            + String(format: "%.1f s", result.elapsed))
        return result
    }

    // MARK: steps

    private func submit(_ input: GenerationInput, budget: inout Budget,
                        progress: @escaping (Stage, Double) -> Void) async throws -> AcceptedJob {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard budget.remaining > 0 else {
                throw EngineError.timedOut(seconds: policy.totalTimeout)
            }
            let boundary = MultipartForm.boundary()
            let request = HTTPRequest(
                method: "POST",
                url: ServerURL.endpoint(baseURL, "generate"),
                headers: ["Content-Type": MultipartForm.contentType(boundary: boundary),
                          "Accept": "application/json"],
                body: MultipartForm.photoBody(input, boundary: boundary))
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                attempt += 1
                log("remote: upload failed (\(error.localizedDescription)), retrying")
                try await pause(policy.backoff(attempt: attempt), budget: &budget)
                continue
            }
            switch response.status {
            case 200, 201, 202:
                guard let accepted = AcceptedJob.decode(response.body) else {
                    throw EngineError.badResponse("no job_id in the /generate answer")
                }
                return accepted
            case 503:
                let api = ApiErrorBody.decode(response.body)
                guard RetryPolicy.retryable(code: api?.code) else {
                    throw EngineError.server(status: 503,
                                             code: api?.code ?? "service_unavailable",
                                             message: api?.message ?? "service unavailable")
                }
                attempt += 1
                let wait = policy.backoff(attempt: attempt)
                log("remote: server busy (\(api?.code ?? "503")), retrying in "
                    + String(format: "%.0f s", wait))
                progress(.queued, 0)
                try await pause(wait, budget: &budget)
            default:
                throw Self.error(status: response.status, body: response.body)
            }
        }
    }

    private func waitForCompletion(jobID: String, budget: inout Budget,
                                   progress: @escaping (Stage, Double) -> Void) async throws -> JobStatus {
        let url = ServerURL.endpoint(baseURL, "jobs/\(jobID)")
        var pollIndex = 0
        var retryAttempt = 0
        while true {
            try Task.checkCancellation()
            guard budget.remaining > 0 else {
                throw EngineError.timedOut(seconds: policy.totalTimeout)
            }
            try await pause(policy.pollDelay(pollIndex), budget: &budget)
            pollIndex += 1

            let response: HTTPResponse
            do {
                response = try await transport.send(
                    HTTPRequest(method: "GET", url: url,
                                headers: ["Accept": "application/json"]))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                retryAttempt += 1
                log("remote: status poll failed (\(error.localizedDescription))")
                try await pause(policy.backoff(attempt: retryAttempt), budget: &budget)
                continue
            }

            switch response.status {
            case 200:
                retryAttempt = 0
                guard let status = JobStatus.decode(response.body) else {
                    throw EngineError.badResponse("/jobs/\(jobID) did not decode")
                }
                if status.isDone {
                    progress(.finishing, 1)
                    return status
                }
                if status.isFailed {
                    let failure = status.failure
                        ?? JobFailure(code: "job_failed",
                                      message: "the server reported the job as failed")
                    throw EngineError.jobFailed(code: failure.code,
                                                message: failure.message)
                }
                progress(status.stage, status.progress)
            case 503:
                let api = ApiErrorBody.decode(response.body)
                guard RetryPolicy.retryable(code: api?.code) else {
                    throw EngineError.server(status: 503,
                                             code: api?.code ?? "service_unavailable",
                                             message: api?.message ?? "service unavailable")
                }
                retryAttempt += 1
                try await pause(policy.backoff(attempt: retryAttempt), budget: &budget)
            case 404:
                throw EngineError.server(status: 404, code: "unknown_job",
                                         message: "job \(jobID) not found")
            default:
                throw Self.error(status: response.status, body: response.body)
            }
        }
    }

    private func fetchResult(jobID: String, status: JobStatus, input: GenerationInput,
                             budget: inout Budget) async throws -> (Data, PageMetadata) {
        let pngURL = ServerURL.endpoint(baseURL, "jobs/\(jobID)/result.png")
        var png: Data?
        var retryAttempt = 0
        while png == nil {
            try Task.checkCancellation()
            guard budget.remaining > 0 else {
                throw EngineError.timedOut(seconds: policy.totalTimeout)
            }
            do {
                let response = try await transport.send(
                    HTTPRequest(method: "GET", url: pngURL))
                if response.status == 200, !response.body.isEmpty {
                    png = response.body
                    break
                }
                let api = ApiErrorBody.decode(response.body)
                let retryable = response.status == 409
                    || RetryPolicy.retryable(status: response.status, code: api?.code)
                guard retryable else {
                    throw Self.error(status: response.status, body: response.body)
                }
                retryAttempt += 1
                try await pause(policy.backoff(attempt: retryAttempt), budget: &budget)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as EngineError {
                throw error
            } catch {
                try Task.checkCancellation()
                retryAttempt += 1
                try await pause(policy.backoff(attempt: retryAttempt), budget: &budget)
            }
        }
        guard let data = png else {
            throw EngineError.badResponse("result.png was not downloaded")
        }

        // result.json is metadata only: a failure here must not lose the page.
        var meta: ResultMetadata?
        let jsonURL = ServerURL.endpoint(baseURL, "jobs/\(jobID)/result.json")
        if let response = try? await transport.send(HTTPRequest(method: "GET", url: jsonURL)),
           response.status == 200 {
            meta = ResultMetadata.decode(response.body)
        }

        let timings: [String: Double]
        if let t = meta?.timings, !t.isEmpty {
            timings = t
        } else {
            timings = status.timings
        }
        let metadata = PageMetadata(
            engine: .localServer,
            model: meta?.modelID ?? status.modelID,
            seed: meta?.seed ?? status.seed ?? input.seed.map { Int($0) },
            steps: meta?.steps ?? status.steps,
            cfg: meta?.cfg ?? status.cfg,
            width: meta?.width ?? status.result?.width,
            height: meta?.height ?? status.result?.height,
            jobID: jobID,
            recipe: meta?.recipe ?? status.recipe,
            timings: timings)
        return (data, metadata)
    }

    // MARK: budget / helpers

    /// Tracks the 10-minute budget across upload, polling and download.
    /// Sleeps count toward it even when the injected sleep returns instantly
    /// (tests), and wall-clock time counts when it is longer (real network).
    struct Budget {
        let limit: TimeInterval
        let started = Date()
        private(set) var slept: TimeInterval = 0

        init(limit: TimeInterval) { self.limit = limit }

        var elapsed: TimeInterval {
            max(slept, Date().timeIntervalSince(started))
        }

        var remaining: TimeInterval { max(0, limit - elapsed) }

        mutating func charge(_ seconds: TimeInterval) -> TimeInterval {
            let capped = max(0, min(seconds, remaining))
            slept += capped
            return capped
        }
    }

    private func pause(_ seconds: TimeInterval, budget: inout Budget) async throws {
        let capped = budget.charge(seconds)
        guard capped > 0 else { return }
        try await sleep(capped)
    }

    public static func error(status: Int, body: Data) -> EngineError {
        if let api = ApiErrorBody.decode(body) {
            return .server(status: status, code: api.code, message: api.message)
        }
        let text = String(decoding: body.prefix(160), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .server(status: status, code: "http_\(status)",
                       message: text.isEmpty ? "unexpected HTTP \(status)" : text)
    }
}
