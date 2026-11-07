import XCTest
@testable import CraftRoomCore

/// Engine defaults, stage labels/progress and aspect mapping — the pieces the
/// UI reads directly, so a drift here is a visible product change.
final class EngineTypesTests: XCTestCase {
    // MARK: defaults (plan T3.4)

    func testFirstLaunchUsesOnDeviceOnlyWhenThePayloadIsInstalled() {
        XCTAssertEqual(EngineSelection.initialEngine(payloadInstalled: true),
                       .onDevice)
        XCTAssertEqual(EngineSelection.initialEngine(payloadInstalled: false),
                       .localServer)
        XCTAssertEqual(EngineSelection.initialBaseURL(saved: nil),
                       ServerURL.default)
        let custom = URL(string: "http://10.0.0.5:9000")!
        XCTAssertEqual(EngineSelection.initialBaseURL(saved: custom), custom)
    }

    func testASavedChoiceAlwaysWins() {
        XCTAssertEqual(EngineSelection.resolve(saved: .localServer,
                                               payloadInstalled: true),
                       .localServer)
        XCTAssertEqual(EngineSelection.resolve(saved: .onDevice,
                                               payloadInstalled: false),
                       .onDevice)
        XCTAssertEqual(EngineSelection.resolve(saved: nil,
                                               payloadInstalled: false),
                       .localServer)
        XCTAssertEqual(EngineSelection.resolve(saved: nil,
                                               payloadInstalled: true),
                       .onDevice)
    }

    func testEngineIdentityIsStableForPersistence() {
        XCTAssertEqual(EngineID.onDevice.rawValue, "on_device")
        XCTAssertEqual(EngineID.localServer.rawValue, "local_server")
        XCTAssertEqual(Set(EngineID.allCases.map(\.rawValue)),
                       ["on_device", "local_server"])
        XCTAssertTrue(EngineID.localServer.isRemote)
        XCTAssertFalse(EngineID.onDevice.isRemote)
    }

    // MARK: stages

    func testServerStageMapping() {
        XCTAssertEqual(Stage.from(server: "queued"), .queued)
        XCTAssertEqual(Stage.from(server: "preparing"), .preparing)
        XCTAssertEqual(Stage.from(server: "uploading"), .preparing)
        XCTAssertEqual(Stage.from(server: "generating"), .rendering)
        XCTAssertEqual(Stage.from(server: "postprocessing"), .finishing)
        XCTAssertEqual(Stage.from(server: "done"), .done)
        XCTAssertEqual(Stage.from(server: "failed"), .failed)
        XCTAssertEqual(Stage.from(server: nil), .queued)
        XCTAssertEqual(Stage.from(server: "GENERATING"), .rendering)
    }

    func testUserFacingStageLabels() {
        XCTAssertEqual(Stage.uploading.label, "Uploading photo")
        XCTAssertEqual(Stage.preparing.label, "Tracing edges")
        XCTAssertEqual(Stage.rendering.label, "Drawing lines")
        XCTAssertEqual(Stage.rendering.label(progress: 0.41), "Drawing lines 41 %")
        XCTAssertEqual(Stage.rendering.label(progress: 0), "Drawing lines")
        XCTAssertEqual(Stage.finishing.label, "Finishing")
        XCTAssertEqual(Stage.done.label, "Done")
        XCTAssertEqual(Stage.failed.label, "Failed")
        XCTAssertEqual(Stage.queued.label, "Queued on desktop2")
    }

    func testOverallProgressRisesAcrossEveryStageBoundary() {
        var last = -1.0
        let samples: [(Stage, Double)] = [
            (.uploading, 0), (.uploading, 1),
            (.queued, 0),
            (.preparing, 0), (.preparing, 1),
            (.rendering, 0), (.rendering, 0.5), (.rendering, 1),
            (.finishing, 0),
            (.done, 1),
        ]
        for (stage, fraction) in samples {
            let value = stage.overallProgress(fraction)
            XCTAssertGreaterThan(value, last, "\(stage) \(fraction)")
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
            last = value
        }
        XCTAssertEqual(Stage.done.overallProgress(1), 1)
        XCTAssertEqual(Stage.rendering.overallProgress(0.41),
                       0.15 + 0.79 * 0.41, accuracy: 1e-9)
        XCTAssertEqual(Stage.rendering.overallProgress(9), 0.94, accuracy: 1e-9)
        XCTAssertEqual(Stage.rendering.overallProgress(-1), 0.15, accuracy: 1e-9)
    }

    // MARK: aspect

    func testAspectNormalisationMirrorsTheServer() {
        XCTAssertEqual(AspectRequest.normalise("auto"), "auto")
        XCTAssertEqual(AspectRequest.normalise("  Portrait "), "portrait")
        XCTAssertEqual(AspectRequest.normalise("4:3"), "4:3")
        XCTAssertEqual(AspectRequest.normalise("4x3"), "4:3")
        XCTAssertEqual(AspectRequest.normalise("4 / 3"), "4:3")
        XCTAssertEqual(AspectRequest.normalise("16 : 9"), "16:9")
        XCTAssertNil(AspectRequest.normalise("banana"))
        XCTAssertNil(AspectRequest.normalise(""))
        XCTAssertNil(AspectRequest.normalise("0:0"))
        XCTAssertNil(AspectRequest.normalise("100:1"))
        XCTAssertNil(AspectRequest.normalise("4:3:2"))
        XCTAssertNil(AspectRequest.normalise(String(repeating: "4", count: 40)))
    }

    func testAspectLabelDerivedFromAPhoto() {
        XCTAssertEqual(AspectRequest.label(forWidth: 768, height: 512),
                       "landscape")
        XCTAssertEqual(AspectRequest.label(forWidth: 512, height: 768),
                       "portrait")
        XCTAssertEqual(AspectRequest.label(forWidth: 768, height: 760),
                       "square")
        XCTAssertEqual(AspectRequest.label(forWidth: 0, height: 0), "auto")
        XCTAssertEqual(AspectRequest.auto, "auto")
    }

    // MARK: error copy

    func testErrorCopySaysWhatToDo() {
        let unreachable = EngineError.unreachable(
            base: "http://192.168.68.92:8124", detail: "timed out")
        XCTAssertTrue(unreachable.errorDescription!.contains("Test connection"))

        let comfy = EngineError.server(status: 503, code: "comfyui_unavailable",
                                       message: "down")
        XCTAssertTrue(comfy.errorDescription!.contains("Start ComfyUI"))
        XCTAssertTrue(comfy.isTransient)

        let vram = EngineError.server(status: 503, code: "vram_low", message: "busy")
        XCTAssertTrue(vram.errorDescription!.contains("GPU is busy"))

        let invalid = EngineError.server(status: 422, code: "invalid_input",
                                         message: "photo is too small")
        XCTAssertTrue(invalid.errorDescription!.contains("photo is too small"))
        XCTAssertFalse(invalid.isTransient)

        let model = EngineError.server(status: 503, code: "model_unavailable",
                                       message: "missing")
        XCTAssertTrue(model.errorDescription!.contains("deploy.sh"))

        XCTAssertTrue(EngineError.payloadMissing.errorDescription!
            .contains("on-device models are not installed"))
        XCTAssertTrue(EngineError.timedOut(seconds: 600).errorDescription!
            .contains("10 minutes"))
        XCTAssertTrue(EngineError.invalidURL("nope").errorDescription!
            .contains("not a server address"))
        XCTAssertFalse(EngineError.cancelled.isTransient)
    }

    func testPageMetadataRoundTripsThroughJSON() throws {
        let meta = PageMetadata(engine: .localServer,
                                model: "craftroom-canny1200", seed: 42,
                                steps: 30, cfg: 9, width: 768, height: 512,
                                jobID: "abc", recipe: "canny_edge_v1",
                                timings: ["total_s": 19.99])
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(PageMetadata.self, from: data)
        XCTAssertEqual(back, meta)
        XCTAssertEqual(back.engine, "local_server")
    }
}
