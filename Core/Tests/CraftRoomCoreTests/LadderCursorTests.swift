import XCTest
@testable import CraftRoomCore

/// The build-10 crash cursor: the thing that keeps a cell which kills the
/// process from restarting the whole matrix forever. Everything here is the
/// policy the app depends on (attempt ceiling, AUTO-FAIL recovery, exhaustion).
final class LadderCursorTests: XCTestCase {
    private let labels = ["cpuAndNeuralEngine/sdpa/1", "cpuAndNeuralEngine/split_einsum/1",
                          "cpuOnly/sdpa/1"]

    private func fresh() -> LadderCursor {
        LadderCursor(ladderID: LadderCursor.ladderID(for: labels), labels: labels)
    }

    func testFreshCursorIsAllPending() {
        var c = fresh()
        XCTAssertEqual(c.cells.count, 3)
        XCTAssertFalse(c.isComplete, "a fresh ladder must run")
        XCTAssertEqual(c.nextIndex(), 0)
        XCTAssertEqual(c.summary(), "pending 3")
    }

    func testLadderIDIsStableAndOrderSensitive() {
        let a = LadderCursor.ladderID(for: labels)
        XCTAssertEqual(a, LadderCursor.ladderID(for: labels), "must survive relaunches")
        XCTAssertNotEqual(a, LadderCursor.ladderID(for: labels.reversed()),
                          "a re-ordered ladder is a different run")
        XCTAssertNotEqual(a, LadderCursor.ladderID(for: Array(labels.dropLast())))
        XCTAssertTrue(a.hasPrefix("3-"))
    }

    func testAStaleCursorForAnotherLadderDoesNotApply() {
        var c = fresh()
        c.settle(0, .done)
        let other = LadderCursor(ladderID: LadderCursor.ladderID(for: labels.reversed()),
                                 labels: labels.reversed())
        XCTAssertNotEqual(c.ladderID, other.ladderID,
                          "the app drops a cursor whose ladder id differs")
    }

    func testHappyPathAdvancesAndCompletes() {
        var c = fresh()
        for i in 0..<3 {
            let idx = c.nextIndex()
            XCTAssertEqual(idx, i)
            guard let idx else { return XCTFail("no next cell") }
            XCTAssertEqual(c.begin(idx), 1, "first attempt")
            c.settle(idx, .done)
        }
        XCTAssertNil(c.nextIndex())
        XCTAssertTrue(c.isComplete)
        XCTAssertEqual(c.summary(), "done 3")
    }

    func testRestartInsideACellRetriesOnceThenFails() {
        // cell 0 finished, cell 1 starts and the process dies inside
        // MLModel(contentsOf:) — the cursor on disk still says `started`.
        var recovered = fresh()
        recovered.settle(0, .done)
        _ = recovered.begin(1)
        let r = recovered.recoverAfterRestart()
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.label, "cpuAndNeuralEngine/split_einsum/1")
        XCTAssertEqual(r.first?.attempts, 1)
        XCTAssertEqual(r.first?.willRetry, true, "one retry is allowed")
        XCTAssertEqual(recovered.state(1), .pending)
        XCTAssertEqual(recovered.nextIndex(), 1, "the retry is the next cell")

        // and it dies again → recorded failed, ladder advances past it
        _ = recovered.begin(1)
        XCTAssertEqual(recovered.attempts(1), 2)
        let r2 = recovered.recoverAfterRestart()
        XCTAssertEqual(r2.first?.willRetry, false)
        XCTAssertEqual(recovered.state(1), .failed)
        XCTAssertEqual(recovered.nextIndex(), 2, "advance to the next cell")
        XCTAssertEqual(recovered.summary(), "done 1 failed 1 pending 1")
    }

    func testAttemptsAreCappedAtTwo() {
        var c = fresh()
        _ = c.begin(0)
        _ = c.recoverAfterRestart()
        _ = c.begin(0)
        _ = c.recoverAfterRestart()
        XCTAssertEqual(c.attempts(0), 2)
        XCTAssertEqual(c.state(0), .failed)
        XCTAssertEqual(c.nextIndex(), 1, "a dead cell is skipped, the ladder advances")
        XCTAssertFalse(c.isComplete, "other cells may still run")
        // and the whole matrix dead → nothing left to offer
        for i in 1..<c.cells.count {
            _ = c.begin(i)
            _ = c.recoverAfterRestart()
            _ = c.begin(i)
            _ = c.recoverAfterRestart()
        }
        XCTAssertNil(c.nextIndex(), "a 2-of-2 dead matrix must not offer more work")
        XCTAssertTrue(c.isComplete)
    }

    func testAllCellsFailedMeansNoLoop() {
        var c = fresh()
        for i in 0..<c.cells.count {
            _ = c.begin(i)
            _ = c.recoverAfterRestart()   // killed every time
            _ = c.begin(i)
            _ = c.recoverAfterRestart()
        }
        XCTAssertTrue(c.isComplete, "a relaunch on this cursor must not loop")
        XCTAssertNil(c.nextIndex())
        XCTAssertEqual(c.summary(), "failed 3")
    }

    func testSkippedCellsSettleWithoutAnAttempt() {
        var c = fresh()
        c.skip(0)
        XCTAssertEqual(c.state(0), .skipped)
        XCTAssertEqual(c.attempts(0), 0, "a refusal is not an attempt")
        XCTAssertEqual(c.nextIndex(), 1)
        c.skip(1)
        c.skip(2)
        XCTAssertTrue(c.isComplete)
        XCTAssertEqual(c.summary(), "skipped 3")
    }

    func testJSONRoundTrip() throws {
        var c = fresh()
        _ = c.begin(0)
        let data = try c.json()
        let back = try LadderCursor.decode(data)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.maxAttempts, LadderCursor.defaultMaxAttempts)
    }

    func testOutOfBoundsIsHarmless() {
        var c = fresh()
        XCTAssertEqual(c.begin(9), 0)
        c.settle(9, .done)
        c.skip(-1)
        XCTAssertNil(c.state(-1))
        XCTAssertEqual(c.attempts(9), 0)
    }
}

/// The estimated-skip preflight: hypothesis A as an executable rule.
final class MemoryPreflightTests: XCTestCase {
    func testEstimateBakesTheContractNumbers() {
        // device_v2_io_contract.json: palettized 3,816,113,664 params → 7,277 MiB
        // of fp16; the unpalettized package measures 7,287 MiB.
        XCTAssertEqual(MemoryPreflight.palettizedFP16WeightsMiB, 7_250,
                       accuracy: 1, "baked estimate must stay inside the contract figures")
        XCTAssertEqual(MemoryPreflight.workingSetMarginMiB, 1_500, accuracy: 0)
    }

    func testOnlyCPUPalettizedCellsGetAnEstimate() {
        XCTAssertEqual(MemoryPreflight.cpuDequantEstimateMiB(units: "cpuOnly",
                         modelName: "Unet_ControlNet_canny1200_6bit"),
                       MemoryPreflight.palettizedFP16WeightsMiB)
        XCTAssertNil(MemoryPreflight.cpuDequantEstimateMiB(units: "cpuAndNeuralEngine",
                       modelName: "Unet_ControlNet_canny1200_6bit"),
                       "ANE keeps the LUT compressed: always attempt")
        XCTAssertNil(MemoryPreflight.cpuDequantEstimateMiB(units: "all",
                       modelName: "Unet_ControlNet_canny1200_6bit"))
        XCTAssertNil(MemoryPreflight.cpuDequantEstimateMiB(units: "cpuOnly",
                       modelName: "VAEDecoder_sdxl_fp32"), "not a palettized UNet")
    }

    func testSkipWhenHeadroomCannotHoldDequantizedWeights() {
        // 10,000 MB left < 7,250 + 1,500 = 8,750 → this one does fit; use a
        // smaller headroom (what a second model already resident leaves).
        let tight = MemoryPreflight.decideCell(units: "cpuOnly",
            modelName: "Unet_ControlNet_canny1200_6bit", headroomMB: 6_000)
        XCTAssertTrue(tight.isSkip)
        if case .skip(let reason) = tight {
            XCTAssertEqual(reason, MemoryPreflight.cpuDequantReason)
            XCTAssertEqual(reason, "cpu-backend-dequant-estimate")
        }
    }

    func testAttemptWhenHeadroomIsClearAndOnANE() {
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuOnly",
            modelName: "Unet_ControlNet_canny1200_6bit", headroomMB: 12_273), .attempt,
            "the 16 GB iPad's empty budget clears the estimate — attempt and measure")
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuAndNeuralEngine",
            modelName: "Unet_ControlNet_canny1200_6bit", headroomMB: 1_000), .attempt,
            "ANE/GPU cells are never refused")
    }

    func testUnknownHeadroomAttemptsAndForceOverrides() {
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuOnly",
            modelName: "Unet_ControlNet_canny1200_6bit", headroomMB: nil), .attempt,
            "an unmeasurable budget must not silently drop cells")
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuOnly",
            modelName: "Unet_ControlNet_canny1200_6bit",
            headroomMB: 1_000, force: true), .attempt,
            "auto.json force:true overrides the estimate")
    }

    func testDetailLineCarriesTheNumbers() {
        let d = MemoryPreflight.detail(headroomMB: 6_000,
                                      estimateMB: MemoryPreflight.palettizedFP16WeightsMiB)
        XCTAssertTrue(d.contains("needs 8750 MB"), d)
        XCTAssertTrue(d.contains("of 6000 MB"), d)
        XCTAssertTrue(d.contains("estimate 7250"), d)
    }
}

/// Plan B plumbing: the manifest stays `mlmodelc` by default and `form` is
/// additive; the device-compile cache name is a pure function.
final class ModelFormTests: XCTestCase {
    private func manifest(_ json: String) throws -> PayloadManifestV2 {
        try PayloadManifestV2.decode(Data(json.utf8))
    }

    func testBundledManifestIsStillTheCompiledForm() throws {
        let m = try PayloadManifestV2.bundled()
        XCTAssertEqual(try m.form(forVariant: "sdpa"), .mlmodelc,
                       "the served manifest must not change shape or default")
        XCTAssertEqual(m.form(forModelNamed: "Unet_ControlNet_canny1200_6bit"), .mlmodelc)
        XCTAssertEqual(m.form(forModelNamed: "VAEDecoder_sdxl_fp32.mlmodelc"), .mlmodelc)
        XCTAssertNil(m.modelForms, "no plan-B flags in the shipped manifest")
    }

    func testFormIsReadFromTheVariantAndTheModelFormsMap() throws {
        // "form":"mlpackage" inside the variant entry
        let m = try manifest("""
        {"version":"device-v2","urlBase":"https://example.test/p","models":["M.mlpackage"],
         "variants":{"sdpa":{"model":"M.mlpackage","group":"sdpa","label":"x",
                             "form":"mlpackage"}},
         "defaultVariant":"sdpa","files":[],"totalBytes":0}
        """)
        XCTAssertEqual(try m.form(forVariant: "sdpa"), .mlpackage)
        XCTAssertEqual(m.form(forModelNamed: "M"), .mlpackage)
        XCTAssertEqual(m.form(forModelNamed: "M.mlpackage"), .mlpackage)

        // modelForms map covers shared models that are not variants (the VAE)
        let n = try manifest("""
        {"version":"device-v2","urlBase":"https://example.test/p","models":["M.mlmodelc"],
         "modelForms":{"VAEDecoder_sdxl_fp32.mlmodelc":"mlpackage"},
         "variants":{"sdpa":{"model":"M.mlmodelc","group":"sdpa","label":"x"}},
         "defaultVariant":"sdpa","files":[],"totalBytes":0}
        """)
        XCTAssertEqual(n.form(forModelNamed: "VAEDecoder_sdxl_fp32"), .mlpackage)
        XCTAssertEqual(n.form(forModelNamed: "M"), .mlmodelc)
    }

    func testNeedsDeviceCompile() {
        XCTAssertFalse(ModelForm.mlmodelc.needsDeviceCompile)
        XCTAssertTrue(ModelForm.mlpackage.needsDeviceCompile)
    }

    func testCompileCacheNameIsContentKeyed() {
        let a = DeviceCompileCache.contentKey(paths: ["M/a", "M/b"], sizes: [1, 2],
                                             sha256s: ["aa", "bb"])
        let same = DeviceCompileCache.contentKey(paths: ["M/b", "M/a"], sizes: [2, 1],
                                                sha256s: ["bb", "aa"])
        XCTAssertEqual(a, same, "key must be order independent")
        let changed = DeviceCompileCache.contentKey(paths: ["M/a", "M/b"], sizes: [1, 3],
                                                   sha256s: ["aa", "cc"])
        XCTAssertNotEqual(a, changed, "a re-baked model must invalidate the cache")

        XCTAssertEqual(DeviceCompileCache.cacheDirectoryName(model: "M.mlpackage",
                                                             contentKey: a),
                       "M-\(a).mlmodelc")
        XCTAssertEqual(DeviceCompileCache.cacheDirectoryName(model: "M.mlmodelc",
                                                             contentKey: a),
                       "M-\(a).mlmodelc", "one cache name per model, whatever the form")
        XCTAssertTrue(DeviceCompileCache.cacheDirectoryName(
            model: "Weird Name (v2).mlpackage", contentKey: "x").allSatisfy {
                $0.isLetter || $0.isNumber || "-_.:".contains($0)
            }, "must be a safe path component")
    }

    func testContentKeyFromManifestEntries() throws {
        let m = try PayloadManifestV2.bundled()
        let sdpa = DeviceCompileCache.contentKey(
            for: try m.entries(forVariant: "sdpa"),
            modelDirectory: "Unet_ControlNet_canny1200_6bit.mlmodelc")
        let split = DeviceCompileCache.contentKey(
            for: try m.entries(forVariant: "split_einsum"),
            modelDirectory: "Unet_ControlNet_canny1200_split_einsum_6bit.mlmodelc")
        XCTAssertNotEqual(sdpa, split)
        XCTAssertEqual(sdpa.count, 16, "fnv1a64 in hex")
    }
}
