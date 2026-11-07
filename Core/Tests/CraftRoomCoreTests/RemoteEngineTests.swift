import XCTest
@testable import CraftRoomCore

/// The remote client's state machine, driven by a scripted transport: upload,
/// poll, backoff on 503, job failure, missing artefacts, health and
/// cancellation. No network, no real sleeping.
final class RemoteEngineTests: XCTestCase {
    // MARK: fixtures

    private enum FakeError: Error, LocalizedError {
        case offline
        var errorDescription: String? { "offline" }
    }

    /// Returns responses in order and records every request; a call beyond the
    /// script repeats the last entry (so a poll loop cannot run dry silently).
    private final class FakeTransport: HTTPTransport {
        private(set) var requests: [HTTPRequest] = []
        private var responses: [HTTPResponse]
        private let failure: FakeError?

        init(_ responses: [HTTPResponse], failOn: Int? = nil) {
            self.responses = responses
            self.failure = failOn == nil ? nil : .offline
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            requests.append(request)
            if let failure, requests.count == 1 { throw failure }
            if responses.count > 1 {
                return responses.removeFirst()
            }
            return responses[0]
        }
    }

    private func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"],
                     body: Data(text.utf8))
    }

    private func accepted(_ id: String = "job1") -> HTTPResponse {
        json("{\"job_id\":\"\(id)\",\"state\":\"queued\",\"stage\":\"queued\",\"queue_position\":1}",
             status: 202)
    }

    private func status(_ state: String, stage: String, progress: Double,
                        error: String? = nil) -> HTTPResponse {
        let errorBlock = error.map { "\"error\":{\"code\":\"\($0)\",\"message\":\"boom\"}," }
            ?? "\"error\":null,"
        return json("""
        {"job_id":"job1","state":"\(state)","stage":"\(stage)","progress":\(progress),
         \(errorBlock)"settings":{"model_id":"craftroom-canny1200","steps":30,"cfg":9.0,"seed":42},
         "timings":{"total_s":20.01},"result":{"width":768,"height":512}}
        """)
    }

    private var png: Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: [0, 0, 0, 13])
        data.append(contentsOf: [0x49, 0x48, 0x44, 0x52])
        data.append(contentsOf: [0, 0, 0x03, 0x00, 0, 0, 0x02, 0x00])
        data.append(contentsOf: [0x01, 0x02, 0x03])
        return data
    }

    private func resultJSON() -> HTTPResponse {
        json("""
        {"schema":"craftroom.api.result.v1","job_id":"job1",
         "model":{"id":"craftroom-canny1200","sha256":"c7963a72737e90ff946c79a9757d297a3f867590278f66b9410eea8ed29aa3f0"},
         "settings":{"steps":30,"cfg":9.0,"seed":7,"recipe":"canny_edge_v1"},
         "output":{"width":768,"height":512,"png_bytes":11},
         "timings":{"total_s":19.99,"generate_s":19.66}}
        """)
    }

    private let input = GenerationInput(photo: Data([0xFF, 0xD8, 0xFF]), aspect: "landscape", seed: 42)

    private func makeEngine(_ transport: HTTPTransport,
                            policy: RetryPolicy = RetryPolicy(pollInterval: 0.01,
                                                             initialBackoff: 2,
                                                             maxBackoff: 30,
                                                             totalTimeout: 600),
                            sleeps: SleepLog? = nil) -> RemoteEngine {
        RemoteEngine(baseURL: ServerURL.default, transport: transport, policy: policy,
                     sleep: { seconds in sleeps?.record(seconds) })
    }

    /// Records the delays the policy asked for (and returns immediately).
    private final class SleepLog {
        private(set) var seconds: [TimeInterval] = []
        func record(_ value: TimeInterval) { seconds.append(value) }
    }

    // MARK: happy path

    func testGenerateUploadsPollsAndDownloadsWithStagedProgress() async throws {
        let transport = FakeTransport([
            accepted(),
            status("running", stage: "preparing", progress: 0.1),
            status("running", stage: "generating", progress: 0.42),
            status("running", stage: "postprocessing", progress: 0.98),
            status("done", stage: "done", progress: 1),
            HTTPResponse(status: 200, body: png),
            resultJSON(),
        ])
        let sleeps = SleepLog()
        let engine = makeEngine(transport, sleeps: sleeps)

        var stages: [(Stage, Double)] = []
        let result = try await engine.generate(input) { stage, fraction in
            stages.append((stage, fraction))
        }

        // The upload is the first request and carries the multipart fields.
        XCTAssertEqual(transport.requests.first?.method, "POST")
        XCTAssertEqual(transport.requests.first?.url.lastPathComponent, "generate")
        let contentType = transport.requests.first?.headers["Content-Type"] ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: transport.requests.first?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"photo\""))
        XCTAssertTrue(body.contains("name=\"aspect\""))
        XCTAssertTrue(body.contains("name=\"seed\""))

        // Then one poll per status, then the two artefacts.
        XCTAssertEqual(transport.requests.count, 7)
        XCTAssertEqual(transport.requests[1].url.lastPathComponent, "job1")
        XCTAssertEqual(transport.requests[5].url.lastPathComponent, "result.png")
        XCTAssertEqual(transport.requests[6].url.lastPathComponent, "result.json")

        // Progress: upload, queue, then the server stages, then done.
        XCTAssertEqual(stages.first?.0, .uploading)
        XCTAssertEqual(stages.last?.0, .done)
        XCTAssertEqual(stages.last?.1, 1)
        XCTAssertTrue(stages.contains { $0.0 == .queued })
        XCTAssertTrue(stages.contains { $0.0 == .preparing })
        XCTAssertTrue(stages.contains { $0.0 == .rendering && $0.1 == 0.42 })
        XCTAssertTrue(stages.contains { $0.0 == .finishing })
        for (previous, next) in zip(stages, stages.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.0.overallProgress(next.1),
                                        previous.0.overallProgress(previous.1),
                                        "progress must never go backwards")
        }

        // The page and its metadata.
        XCTAssertEqual(result.png, png)
        XCTAssertEqual(result.width, 768)
        XCTAssertEqual(result.height, 512)
        XCTAssertEqual(result.metadata.model, "craftroom-canny1200")
        XCTAssertEqual(result.metadata.seed, 7)          // result.json wins over the request
        XCTAssertEqual(result.metadata.steps, 30)
        XCTAssertEqual(result.metadata.jobID, "job1")
        XCTAssertEqual(result.metadata.recipe, "canny_edge_v1")
        XCTAssertEqual(result.metadata.timings["generate_s"] ?? 0, 19.66, accuracy: 1e-9)
        XCTAssertEqual(result.metadata.engine, "local_server")
        XCTAssertGreaterThanOrEqual(result.elapsed, 0)

        // Poll cadence is the policy's, not a busy loop.
        XCTAssertEqual(sleeps.seconds.count, 4)
        for value in sleeps.seconds {
            XCTAssertLessThanOrEqual(value, 0.02)
        }
    }

    // MARK: retries

    func testRetriesA503WithExponentialBackoffThenSucceeds() async throws {
        let busy = json("{\"error\":{\"code\":\"queue_full\",\"message\":\"queue full (4 jobs)\"}}",
                        status: 503)
        let transport = FakeTransport([
            busy, busy, accepted(),
            status("done", stage: "done", progress: 1),
            HTTPResponse(status: 200, body: png),
            resultJSON(),
        ])
        let sleeps = SleepLog()
        let engine = makeEngine(transport, sleeps: sleeps)
        let result = try await engine.generate(input) { _, _ in }
        XCTAssertEqual(result.width, 768)
        // The two 503 answers cost 2 s and 4 s; the successful poll adds the
        // policy's short poll interval after them.
        XCTAssertEqual(Array(sleeps.seconds.prefix(2)), [2, 4])
    }

    func testRetriesATransientUploadFailure() async throws {
        let transport = FakeTransport([
            accepted(),
            status("done", stage: "done", progress: 1),
            HTTPResponse(status: 200, body: png),
            resultJSON(),
        ], failOn: 1)
        let engine = makeEngine(transport)
        let result = try await engine.generate(input) { _, _ in }
        XCTAssertEqual(result.png, png)
        XCTAssertEqual(transport.requests.count, 5)
    }

    func testGivesUpWhenTheBudgetIsExhausted() async throws {
        let busy = json("{\"error\":{\"code\":\"vram_low\",\"message\":\"busy\"}}",
                        status: 503)
        let transport = FakeTransport([busy])
        let sleeps = SleepLog()
        let policy = RetryPolicy(initialBackoff: 5, maxBackoff: 30, totalTimeout: 12)
        let engine = makeEngine(transport, policy: policy, sleeps: sleeps)
        do {
            _ = try await engine.generate(input) { _, _ in }
            XCTFail("expected a timeout")
        } catch let error as EngineError {
            guard case .timedOut(let seconds) = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(seconds, 12)
            XCTAssertTrue(error.errorDescription!.contains("did not finish"))
        }
        XCTAssertEqual(sleeps.seconds.count, 2)
        XCTAssertEqual(sleeps.seconds[0], 5, accuracy: 1e-2)
        // The second wait is capped to what is left of the 12 s budget; the
        // runner's own wall-clock time takes a few milliseconds off it.
        XCTAssertEqual(sleeps.seconds[1], 7, accuracy: 0.05)
        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: failures

    func testARejectedPhotoSurfacesTheServerMessage() async throws {
        let transport = FakeTransport([
            json("{\"error\":{\"code\":\"invalid_input\",\"message\":\"photo is too small\"}}",
                 status: 422),
        ])
        let engine = makeEngine(transport)
        do {
            _ = try await engine.generate(input) { _, _ in }
            XCTFail("expected an error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .server(status: 422, code: "invalid_input",
                                          message: "photo is too small"))
            XCTAssertFalse(error.isTransient)
            XCTAssertTrue(error.errorDescription!.contains("photo is too small"))
        }
    }

    func testAFailedJobCarriesItsCode() async throws {
        let transport = FakeTransport([
            accepted(),
            status("running", stage: "generating", progress: 0.5),
            status("failed", stage: "failed", progress: 0.5, error: "comfy_failed"),
        ])
        let engine = makeEngine(transport)
        do {
            _ = try await engine.generate(input) { _, _ in }
            XCTFail("expected an error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .jobFailed(code: "comfy_failed", message: "boom"))
            XCTAssertTrue(error.errorDescription!.contains("comfy_failed"))
        }
    }

    func testAnUnknownJobIsNotRetried() async throws {
        let transport = FakeTransport([
            accepted(),
            json("{\"error\":{\"code\":\"unknown_job\",\"message\":\"no job\"}}", status: 404),
        ])
        let engine = makeEngine(transport)
        do {
            _ = try await engine.generate(input) { _, _ in }
            XCTFail("expected an error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .server(status: 404, code: "unknown_job",
                                          message: "job job1 not found"))
            XCTAssertTrue(error.errorDescription!.contains("lost track"))
        }
    }

    func testAResultJSONFailureStillReturnsThePage() async throws {
        let transport = FakeTransport([
            accepted(),
            status("done", stage: "done", progress: 1),
            HTTPResponse(status: 200, body: png),
            json("{\"error\":{\"code\":\"result_missing\",\"message\":\"gone\"}}",
                 status: 500),
        ])
        let engine = makeEngine(transport)
        let result = try await engine.generate(input) { _, _ in }
        XCTAssertEqual(result.png, png)
        XCTAssertEqual(result.width, 768)          // from the job snapshot
        XCTAssertEqual(result.height, 512)
        XCTAssertEqual(result.metadata.seed, 42)   // from the job settings
        XCTAssertEqual(result.metadata.model, "craftroom-canny1200")
    }

    func testAnEmptyPhotoIsRejectedLocally() async {
        let engine = makeEngine(FakeTransport([accepted()]))
        do {
            _ = try await engine.generate(GenerationInput(photo: Data())) { _, _ in }
            XCTFail("expected an error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .invalidPhoto("no photo data"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: health

    func testHealthDecodesTheRunningService() async throws {
        let transport = FakeTransport([
            json("""
            {"ok":true,"version":"0.6.0",
             "model":{"id":"craftroom-canny1200","sha256":"c7963a72737e90ff946c79a9757d297a3f867590278f66b9410eea8ed29aa3f0","ok":true},
             "comfyui":{"ok":true,"version":"0.44.0","device":"cuda:0 NVIDIA GeForce RTX 3060",
                        "vram_free_bytes":2621440000,"vram_total_bytes":12884901888},
             "queue":{"queued":0,"max":4}}
            """),
        ])
        let health = try await makeEngine(transport).health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.engine, .localServer)
        XCTAssertEqual(health.baseURL, "http://192.168.68.92:8124")
        XCTAssertEqual(health.comfyVersion, "0.44.0")
        XCTAssertEqual(health.modelSHAShort, "c7963a72737e…")
        XCTAssertNotNil(health.checkedAt)
    }

    func testHealthReportsAnUnreachableHostAsAnActionableError() async {
        let engine = makeEngine(FakeTransport([], failOn: 1))
        do {
            _ = try await engine.health()
            XCTFail("expected an error")
        } catch let error as EngineError {
            guard case .unreachable(let base, _) = error else {
                return XCTFail("expected unreachable, got \(error)")
            }
            XCTAssertEqual(base, "http://192.168.68.92:8124")
            XCTAssertTrue(error.errorDescription!.contains("same Wi-Fi"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: cancellation

    func testCancellingTheTaskStopsPolling() async throws {
        let transport = FakeTransport([
            accepted(),
            status("running", stage: "generating", progress: 0.3),
        ])
        let engine = RemoteEngine(
            baseURL: ServerURL.default, transport: transport,
            policy: RetryPolicy(pollInterval: 0.005, totalTimeout: 60),
            sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        let task = Task { () -> PageResult in
            try await engine.generate(self.input) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected: the polling loop observed the cancellation
        } catch let error as EngineError {
            XCTAssertEqual(error, .cancelled)
        }
    }
}
