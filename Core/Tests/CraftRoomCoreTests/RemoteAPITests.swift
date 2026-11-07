import XCTest
@testable import CraftRoomCore

/// The wire halves of the remote contract: the 202 answer, job snapshots in
/// every state, the structured error body, `/health` and `result.json`.
/// Decoding is tolerant by design — the service may add fields, and a run must
/// not fail because of one unexpected field.
final class RemoteAPITests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: accepted job

    func testDecodesThe202Answer() {
        let accepted = AcceptedJob.decode(data("""
        {"job_id":"e6859f2026a34da68716424e3a27d5ff","state":"queued",
         "stage":"queued","queue_position":1,
         "source":{"width":1280,"height":956},"settings":{},"urls":{}}
        """))
        XCTAssertEqual(accepted?.jobID, "e6859f2026a34da68716424e3a27d5ff")
        XCTAssertEqual(accepted?.state, "queued")
        XCTAssertEqual(accepted?.stage, .queued)
        XCTAssertEqual(accepted?.queuePosition, 1)
    }

    func testRejectsAnAnswerWithoutAJobID() {
        XCTAssertNil(AcceptedJob.decode(data("{\"state\":\"queued\"}")))
        XCTAssertNil(AcceptedJob.decode(Data("<html>oops</html>".utf8)))
    }

    // MARK: job status

    func testDecodesEachDocumentedStage() {
        let stages: [(String, Stage)] = [
            ("queued", .queued),
            ("preparing", .preparing),
            ("uploading", .preparing),
            ("generating", .rendering),
            ("postprocessing", .finishing),
            ("done", .done),
            ("failed", .failed),
        ]
        for (raw, expected) in stages {
            let json = "{\"job_id\":\"abc\",\"state\":\"running\",\"stage\":\"\(raw)\",\"progress\":0.5}"
            XCTAssertEqual(JobStatus.decode(data(json))?.stage, expected, raw)
        }
    }

    func testUnknownStageFallsBackToQueued() {
        let json = "{\"job_id\":\"abc\",\"state\":\"running\",\"stage\":\"teleporting\",\"progress\":0.1}"
        XCTAssertEqual(JobStatus.decode(data(json))?.stage, .queued)
    }

    func testDecodesARunningSnapshotWithSettingsAndTimings() {
        let status = JobStatus.decode(data("""
        {"job_id":"abc","state":"running","stage":"generating","progress":0.42,
         "created_at":"2026-11-07T10:00:00Z","updated_at":"2026-11-07T10:00:19Z",
         "started_at":"2026-11-07T10:00:12Z","finished_at":null,"error":null,
         "request":{"aspect":"landscape","seed":42},
         "settings":{"model_id":"craftroom-canny1200","recipe":"canny_edge_v1",
                     "steps":30,"cfg":9.0,"seed":42,
                     "latent":[768,768],"positive_prompt":"x"},
         "timings":{"prepare_s":0.08,"generate_s":19.66},
         "result":null,"queue_position":null}
        """))
        XCTAssertEqual(status?.state, "running")
        XCTAssertEqual(status?.stage, .rendering)
        XCTAssertEqual(status?.progress ?? 0, 0.42, accuracy: 1e-9)
        XCTAssertEqual(status?.modelID, "craftroom-canny1200")
        XCTAssertEqual(status?.recipe, "canny_edge_v1")
        XCTAssertEqual(status?.steps, 30)
        XCTAssertEqual(status?.cfg ?? 0, 9.0, accuracy: 1e-9)
        XCTAssertEqual(status?.seed, 42)
        XCTAssertEqual(status?.timings["generate_s"] ?? 0, 19.66, accuracy: 1e-9)
        XCTAssertNil(status?.failure)
        XCTAssertFalse(status?.isDone ?? true)
    }

    func testDecodesADoneSnapshotWithResultSize() {
        let status = JobStatus.decode(data("""
        {"job_id":"abc","state":"done","stage":"done","progress":1.0,"error":null,
         "settings":{"model_id":"craftroom-canny1200","steps":30,"cfg":9.0,"seed":7},
         "timings":{"total_s":20.01},
         "result":{"png":"/jobs/abc/result.png","json":"/jobs/abc/result.json",
                   "width":768,"height":512}}
        """))
        XCTAssertTrue(status?.isDone ?? false)
        XCTAssertEqual(status?.result?.width, 768)
        XCTAssertEqual(status?.result?.height, 512)
        XCTAssertEqual(status?.seed, 7)
    }

    func testDecodesAFailedSnapshot() {
        let status = JobStatus.decode(data("""
        {"job_id":"abc","state":"failed","stage":"failed","progress":0.3,
         "error":{"code":"comfy_failed","message":"ComfyUI returned no image"},
         "settings":{},"timings":null,"result":null}
        """))
        XCTAssertTrue(status?.isFailed ?? false)
        XCTAssertEqual(status?.failure?.code, "comfy_failed")
        XCTAssertEqual(status?.failure?.message, "ComfyUI returned no image")
    }

    func testRejectsABodyWithoutAState() {
        XCTAssertNil(JobStatus.decode(data("{\"detail\":\"not found\"}")))
        XCTAssertNil(JobStatus.decode(Data()))
    }

    // MARK: structured errors

    func testDecodesTheErrorBody() {
        let body = ApiErrorBody.decode(data("""
        {"error":{"code":"vram_low","message":"GPU memory is in use on desktop2; retry later",
                  "detail":{"vram_free_bytes":402653184}}}
        """))
        XCTAssertEqual(body?.code, "vram_low")
        XCTAssertEqual(body?.message, "GPU memory is in use on desktop2; retry later")
        XCTAssertEqual(body?.detail, "{\"vram_free_bytes\":402653184}")
        XCTAssertNil(ApiErrorBody.decode(data("{\"ok\":false}")))
    }

    // MARK: health

    func testDecodesHealthIntoTheSettingsRow() {
        let health = ServerHealth.decode(data("""
        {"ok":true,"version":"0.6.0",
         "model":{"id":"craftroom-canny1200",
                  "sha256":"c7963a72737e90ff946c79a9757d297a3f867590278f66b9410eea8ed29aa3f0",
                  "ok":true,"error":null},
         "comfyui":{"ok":true,"version":"0.44.0","url":"http://127.0.0.1:8456",
                    "device":"cuda:0 NVIDIA GeForce RTX 3060",
                    "vram_free_bytes":2621440000,"vram_total_bytes":12884901888,
                    "student_listed":true},
         "queue":{"queued":0,"running":false,"active_job":null,"total":0,"max":4},
         "settings":{"steps":30}}
        """))
        XCTAssertEqual(health?.ok, true)
        XCTAssertEqual(health?.comfyVersion, "0.44.0")
        XCTAssertEqual(health?.modelID, "craftroom-canny1200")
        XCTAssertEqual(health?.modelOK, true)
        XCTAssertEqual(health?.queueMax, 4)
        XCTAssertEqual(health?.device, "cuda:0 NVIDIA GeForce RTX 3060")
        XCTAssertNil(health?.problem)

        let row = health!.engineHealth(baseURL: ServerURL.default,
                                       checkedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(row.ok)
        XCTAssertEqual(row.engine, .localServer)
        XCTAssertEqual(row.comfyVersion, "0.44.0")
        XCTAssertEqual(row.modelSHAShort, "c7963a72737e…")
        XCTAssertEqual(row.queue, "0/4 queued")
        XCTAssertEqual(row.vramFreeMB ?? 0, 2500, accuracy: 1)
        XCTAssertTrue(row.summary.contains("ComfyUI 0.44.0"))
        XCTAssertTrue(row.summary.contains("queue idle"))
    }

    func testHealthReportsTheDownDependency() {
        let health = ServerHealth.decode(data("""
        {"ok":false,"version":"0.6.0",
         "model":{"id":"craftroom-canny1200","sha256":"c7","ok":false,
                  "error":"student file missing"},
         "comfyui":{"ok":false,"version":null,"error":"ConnectionError: refused"},
         "queue":{"queued":2,"running":true,"total":3,"max":4}}
        """))
        XCTAssertEqual(health?.ok, false)
        XCTAssertEqual(health?.comfyOK, false)
        XCTAssertEqual(health?.problem, "ConnectionError: refused")
        let row = health!.engineHealth(baseURL: ServerURL.default)
        XCTAssertFalse(row.ok)
        XCTAssertEqual(row.detail, "ConnectionError: refused")
        XCTAssertEqual(row.queue, "2/4 queued")
    }

    // MARK: result.json

    func testDecodesResultMetadata() {
        let meta = ResultMetadata.decode(data("""
        {"schema":"craftroom.api.result.v1","job_id":"abc",
         "model":{"id":"craftroom-canny1200",
                  "sha256":"c7963a72737e90ff946c79a9757d297a3f867590278f66b9410eea8ed29aa3f0",
                  "controlnet":"controlnet-merged.safetensors"},
         "settings":{"steps":30,"cfg":9.0,"seed":42,"recipe":"canny_edge_v1"},
         "request":{"aspect":"landscape","aspect_mismatch":false},
         "output":{"width":768,"height":512,"png_bytes":473649,"sha256":"aa"},
         "timings":{"prepare_s":0.08,"generate_s":19.66,"total_s":19.99}}
        """))
        XCTAssertEqual(meta?.modelID, "craftroom-canny1200")
        XCTAssertEqual(meta?.seed, 42)
        XCTAssertEqual(meta?.steps, 30)
        XCTAssertEqual(meta?.width, 768)
        XCTAssertEqual(meta?.height, 512)
        XCTAssertEqual(meta?.recipe, "canny_edge_v1")
        XCTAssertEqual(meta?.timings["total_s"] ?? 0, 19.99, accuracy: 1e-9)
    }

    func testPNGHeaderReadsTheSize() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(contentsOf: [0, 0, 0, 13])
        png.append(contentsOf: [0x49, 0x48, 0x44, 0x52])   // "IHDR"
        png.append(contentsOf: [0, 0, 0x03, 0x00])         // 768
        png.append(contentsOf: [0, 0, 0x02, 0x00])         // 512
        let size = PNGHeader.size(png)
        XCTAssertEqual(size?.width, 768)
        XCTAssertEqual(size?.height, 512)
        XCTAssertNil(PNGHeader.size(Data([0x89, 0x50])))
        XCTAssertNil(PNGHeader.size(Data()))
    }
}
