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

/// MemoryPreflight v2 (build 11): the refuse/attempt rules the 16 GB ladder needs.
/// The 6-bit ANE cells' crash-loop is the evidence behind the fp32 CPU rule; the
/// fp16 payload adds the one case where a refusal IS right before an attempt.
final class MemoryPreflightTests: XCTestCase {
    func testEstimatesBakeTheContractNumbers() {
        // device_v2_io_contract.json: palettized 3,816,113,664 params → 7,277 MiB
        // of fp16; the unpalettized package measures 7,287 MiB; fp32 doubles it.
        XCTAssertEqual(MemoryPreflight.fp16WeightsMiB, 7_250)
        XCTAssertEqual(MemoryPreflight.cpuUnpackedFP32MiB, 14_600)
        XCTAssertEqual(MemoryPreflight.packed6BitMiB, 3_000)
        XCTAssertEqual(MemoryPreflight.workingSetMarginMiB, 1_500)
    }

    func testCPUIsRefusedForEveryUnetVariant() {
        for model in ["Unet_ControlNet_canny1200_6bit", "Unet_ControlNet_canny1200_fp16"] {
            let e = MemoryPreflight.estimate(units: "cpuOnly", modelName: model)!
            XCTAssertEqual(e.miB, MemoryPreflight.cpuUnpackedFP32MiB,
                           "the CPU backend widens to fp32 — build-10 climb direction")
            XCTAssertTrue(e.refuses)
            let d = MemoryPreflight.decideCell(units: "cpuOnly", modelName: model,
                                               headroomMB: 12_273)
            XCTAssertEqual(d, .skip(reason: MemoryPreflight.cpuDequantReason),
                           "never load a UNet on CPU on the test iPad — even at full budget")
        }
        XCTAssertNil(MemoryPreflight.estimate(units: "cpuOnly", modelName: "VAEDecoder_sdxl_fp32"),
                     "not a palettized/fp16 UNet — the caller's own rules apply")
    }

    func testPacked6BitCellsAreNeverRefused() {
        let e = MemoryPreflight.estimate(units: "cpuAndNeuralEngine",
                                         modelName: "Unet_ControlNet_canny1200_6bit")!
        XCTAssertFalse(e.refuses, "the packed-size question is what the cell EXISTS to answer")
        XCTAssertEqual(e.miB, MemoryPreflight.packed6BitMiB)
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuAndNeuralEngine",
            modelName: "Unet_ControlNet_canny1200_6bit", headroomMB: 1_000), .attempt,
            "ANE/GPU 6-bit cells are never refused")
    }

    func testFP16OnAcceleratorRefusesOnlyWhenTight() {
        let e = MemoryPreflight.estimate(units: "all",
                                         modelName: "Unet_ControlNet_canny1200_fp16")!
        XCTAssertTrue(e.refuses)
        XCTAssertEqual(e.miB, MemoryPreflight.fp16WeightsMiB)
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuAndNeuralEngine",
            modelName: "Unet_ControlNet_canny1200_fp16", headroomMB: 12_273), .attempt,
            "12.3 GB available > 8,750 MB needed")
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuAndNeuralEngine",
            modelName: "Unet_ControlNet_canny1200_fp16", headroomMB: 8_000),
            .skip(reason: MemoryPreflight.fp16WeightsReason),
            "8 GB available < 8,750 MB needed → jetsam is certain — skip")
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuAndNeuralEngine",
            modelName: "Unet_ControlNet_canny1200_fp16", headroomMB: 8_750), .attempt,
            "exactly enough is enough")
    }

    func testUnknownHeadroomAttemptsAndForceOverrides() {
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuOnly",
            modelName: "Unet_ControlNet_canny1200_6bit", headroomMB: nil), .attempt,
            "an unmeasurable budget must not silently drop cells")
        XCTAssertEqual(MemoryPreflight.decideCell(units: "cpuOnly",
            modelName: "Unet_ControlNet_canny1200_6bit",
            headroomMB: 1_000, force: true), .attempt,
            "auto.json force:true overrides the estimate")
        XCTAssertEqual(MemoryPreflight.decideCell(units: "all",
            modelName: "Unet_ControlNet_canny1200_fp16",
            headroomMB: 1, force: true), .attempt)
    }

    func testDetailLineCarriesTheNumbers() {
        let d = MemoryPreflight.detail(headroomMB: 8_000,
                                       estimateMB: MemoryPreflight.fp16WeightsMiB)
        XCTAssertTrue(d.contains("needs 8750 MB"), d)
        XCTAssertTrue(d.contains("of 8000 MB"), d)
        XCTAssertTrue(d.contains("estimate 7250"), d)
    }
}

/// Build 11 ladder vocabulary: canonical compute-unit names and PLAN lines.
final class LadderUnitsTests: XCTestCase {
    func testCanonicalUnitNames() {
        XCTAssertEqual(LadderUnits.canonical("cpuAndNeuralEngine"), .cpuAndNeuralEngine)
        XCTAssertEqual(LadderUnits.canonical("cpuane"), .cpuAndNeuralEngine)
        XCTAssertEqual(LadderUnits.canonical("ANE"), .cpuAndNeuralEngine)
        XCTAssertEqual(LadderUnits.canonical("CPUAndGPU"), .cpuAndGPU)
        XCTAssertEqual(LadderUnits.canonical("gpu"), .cpuAndGPU)
        XCTAssertEqual(LadderUnits.canonical("cpu_only"), .cpuOnly)
        XCTAssertEqual(LadderUnits.canonical("all"), .all)
        XCTAssertEqual(LadderUnits.canonical("tpu"), .all,
                       "launch-arg parsing keeps the build-10 forgiving default")
        XCTAssertEqual(LadderUnits.canonical(nil), .all)
    }

    func testStrictParsingRejectsUnknown() {
        XCTAssertEqual(LadderUnits.strict("gpu"), .cpuAndGPU)
        XCTAssertEqual(LadderUnits.strict(" ANE "), .cpuAndNeuralEngine)
        XCTAssertNil(LadderUnits.strict("tpu"), "matrix files must not mislabel cells")
        XCTAssertNil(LadderUnits.strict(""))
        XCTAssertNil(LadderUnits.strict(nil))
    }

    func testComputePlanLineFormat() {
        let l = ComputePlanLine.line(variant: "split_einsum", units: "cpuAndNeuralEngine",
                                     ane: 41_203, cpu: 12, gpu: 0, unsupported: 0)
        XCTAssertTrue(l.hasPrefix("PLAN variant=split_einsum units=cpuAndNeuralEngine"
                                  + " ane=41203 cpu=12 gpu=0 unsupported=0"), l)
        let withExtras = ComputePlanLine.line(variant: "fp16", units: "cpuAndGPU",
                                              ane: 0, cpu: 5, gpu: 40_000, unsupported: 0,
                                              planSeconds: 83.4, requiredUnits: "cpuAndGPU")
        XCTAssertTrue(withExtras.contains("plan_s=83.4"), withExtras)
        XCTAssertTrue(withExtras.contains("required=cpuAndGPU"), withExtras)
        let f = ComputePlanLine.failed(variant: "fp16", units: "all",
                                       error: "MLComputePlan needs iOS 18")
        XCTAssertTrue(f.hasPrefix("PLAN failed variant=fp16 units=all error="), f)
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
