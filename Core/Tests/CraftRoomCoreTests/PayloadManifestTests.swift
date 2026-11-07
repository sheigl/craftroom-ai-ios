import XCTest
@testable import CraftRoomCore

/// The `device-v2` manifest is the contract between the Linux build box, the
/// LAN server used for T5 and the app. These tests pin its shape, the byte
/// accounting the download UI shows, the variant selection and the T5 base-URL
/// override.
final class PayloadManifestTests: XCTestCase {
    private func manifest() throws -> PayloadManifestV2 { try PayloadManifestV2.bundled() }

    func testBundledManifestShape() throws {
        let m = try manifest()
        XCTAssertEqual(m.version, "device-v2")
        XCTAssertEqual(m.defaultVariant, "sdpa")
        XCTAssertEqual(Set(m.variants.keys), ["sdpa", "split_einsum", "fp16"],
                       "build 11 adds the fp16 unpalettized fallback variant")
        XCTAssertTrue(m.urlBase.hasPrefix("https://"),
                      "the default base must be the published payload, not a LAN address")
        XCTAssertEqual(m.files.count, 23,
                       "3 UNet trees x 5 files + VAE decoder 5 + 3 embeds")
        for f in m.files {
            XCTAssertEqual(f.sha256.count, 64, "\(f.path): sha256 must be hex-64")
            XCTAssertTrue(f.sha256.allSatisfy { $0.isHexDigit })
            XCTAssertGreaterThan(f.size, 0)
            XCTAssertFalse(f.path.hasPrefix("/"), "paths must be relative to urlBase")
            XCTAssertTrue(["common", "sdpa", "split_einsum", "fp16"].contains(f.group),
                          "\(f.path): unknown group \(f.group)")
        }
    }

    func testByteAccountingMatchesTheT3PayloadDraft() throws {
        let m = try manifest()
        // T3 draft: 18 files / 3,206,033,199 B *including* the optional VAE
        // encoder (136,807,141 B). The app manifest drops the encoder, so the
        // sdpa download must be exactly the draft minus that encoder.
        let sdpa = try m.bytes(forVariant: "sdpa")
        XCTAssertEqual(sdpa, 3_069_226_058)
        XCTAssertEqual(sdpa, 3_206_033_199 - 136_807_141)
        let split = try m.bytes(forVariant: "split_einsum")
        XCTAssertEqual(split, 3_091_920_264)
        XCTAssertLessThan(split - sdpa, 40_000_000,
                          "the two variants differ only in the UNet model.mil")
        XCTAssertEqual(m.totalBytes, m.files.reduce(0) { $0 + $1.size })
    }

    func testVariantSelectionSplitsTheModels() throws {
        let m = try manifest()
        let sdpa = try m.entries(forVariant: "sdpa")
        let split = try m.entries(forVariant: "split_einsum")
        XCTAssertEqual(sdpa.count, 13)
        XCTAssertEqual(split.count, 13)
        let sdpaModel = try m.modelDirectory(forVariant: "sdpa")
        let splitModel = try m.modelDirectory(forVariant: "split_einsum")
        XCTAssertEqual(sdpaModel, "Unet_ControlNet_canny1200_6bit.mlmodelc")
        XCTAssertEqual(splitModel, "Unet_ControlNet_canny1200_split_einsum_6bit.mlmodelc")
        XCTAssertTrue(sdpa.allSatisfy { $0.path.hasPrefix("common/") == false })
        XCTAssertTrue(sdpa.contains { $0.path == "\(sdpaModel)/weights/weight.bin" })
        XCTAssertFalse(sdpa.contains { $0.path.contains("split_einsum") })
        XCTAssertFalse(split.contains { $0.path.contains("canny1200_6bit.mlmodelc") })
        XCTAssertThrowsError(try m.entries(forVariant: "nope"))
    }

    func testTheUNetWeightsAreTheT2Artifact() throws {
        let m = try manifest()
        let weight = try XCTUnwrap(m.files.first {
            $0.path == "Unet_ControlNet_canny1200_6bit.mlmodelc/weights/weight.bin"
        })
        XCTAssertEqual(weight.sha256,
                       "66bf237e6d132d9ad63ac466cdbfdd97f7d251f3f918ca01f5babd5272e361c0")
        XCTAssertEqual(weight.size, 2_867_236_672)
        let split = try XCTUnwrap(m.files.first {
            $0.path.hasSuffix("split_einsum_6bit.mlmodelc/weights/weight.bin")
        })
        XCTAssertEqual(split.sha256, weight.sha256,
                       "same 6-bit LUT weights, only the attention layout differs")
    }

    /// Build 11: the fp16 fallback variant — same frozen student unpalettized,
    /// compiled by GitHub Actions from release `payload-fp16-2026-11-07`.
    func testFP16VariantIsTheUnpalettizedFallback() throws {
        let m = try manifest()
        let fp16 = try m.entries(forVariant: "fp16")
        XCTAssertEqual(fp16.count, 13, "own UNet tree + the shared VAE + embeds")
        XCTAssertEqual(try m.modelDirectory(forVariant: "fp16"),
                       "Unet_ControlNet_canny1200_fp16.mlmodelc")
        XCTAssertFalse(fp16.contains { $0.path.contains("6bit") },
                       "the fp16 download must not carry a 6-bit tree")
        let w = try XCTUnwrap(m.files.first {
            $0.path == "Unet_ControlNet_canny1200_fp16.mlmodelc/weights/weight.bin"
        })
        // 3.82 B params × 2 B ≈ the contract's fp16_bytes_unpalettized figure.
        XCTAssertGreaterThan(w.size, 7_600_000_000)
        XCTAssertNotEqual(w.sha256,
                          "66bf237e6d132d9ad63ac466cdbfdd97f7d251f3f918ca01f5babd5272e361c0",
                          "fp16 weights are not the 6-bit LUT bytes")
        XCTAssertEqual(w.sha256, FP16_WEIGHT_SHA256)
        let bytes = try m.bytes(forVariant: "fp16")
        XCTAssertGreaterThan(bytes, 7_700_000_000, "≈7.64 GB UNet + 202 MB common")
        XCTAssertLessThan(bytes, 8_100_000_000)
    }

    /// The CI-compiled artifact byte for byte (compile run 42375239168; the
    /// compiled weight.bin is the package weight.bin passed through, sha
    /// identical to the runner's `shasum` of the unzipped package).
    private static let FP16_WEIGHT_SHA256 =
        "8770f6cebe95d02aaa40e0c87b28dbcbe790ff3c878b3308822f98d9b81ee723"

    func testHonoursTheT5BaseOverride() throws {
        let m = try manifest()
        let entry = try XCTUnwrap(m.files.first { $0.path.hasSuffix("text_embeds.f16") })
        let lan = "http://192.168.68.83:8099/device_v2/payload/"
        let url = try XCTUnwrap(m.url(for: entry, base: lan))
        XCTAssertEqual(url.absoluteString,
                       "http://192.168.68.83:8099/device_v2/payload/embeds/text_embeds.f16")
        let noSlash = try XCTUnwrap(m.url(for: entry, base: "http://192.168.68.83:8099/device_v2/payload"))
        XCTAssertEqual(noSlash, url)
    }

    func testBaseOverrideFileParsing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(PayloadBaseURL.override(in: dir), "absent file → no override")
        XCTAssertEqual(PayloadBaseURL.resolve(manifestBase: "https://cdn/x", documents: dir),
                       "https://cdn/x")

        let file = dir.appendingPathComponent(PayloadBaseURL.overrideFileName)
        try "\n  http://192.168.68.83:8099/device_v2/payload/  \n\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(PayloadBaseURL.override(in: dir),
                       "http://192.168.68.83:8099/device_v2/payload/")
        XCTAssertEqual(PayloadBaseURL.resolve(manifestBase: "https://cdn/x", documents: dir),
                       "http://192.168.68.83:8099/device_v2/payload/")

        // a scheme-less line is ignored rather than silently treated as a path
        try "192.168.68.83:8099".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(PayloadBaseURL.resolve(manifestBase: "https://cdn/x", documents: dir),
                       "https://cdn/x")
    }

    func testRejectsForeignSchema() {
        let json = #"{"version":"device-v1","urlBase":"x","models":[],"variants":{},"defaultVariant":"sdpa","files":[],"totalBytes":0}"#
        XCTAssertThrowsError(try PayloadManifestV2.decode(Data(json.utf8)))
    }

    /// Build 9 bakes the LAN dev server as the fallback base so a fresh
    /// install downloads the payload with no file push; the override file
    /// still wins whenever it is present.
    func testBakedDevDefaultFallsOutWhenNoOverrideFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lan = "http://192.168.68.83:8123/device_v2/payload"
        let lanSlash = "http://192.168.68.83:8123/device_v2/payload/"
        // no file → baked dev default, slash-normalised
        XCTAssertEqual(PayloadBaseURL.resolve(manifestBase: "https://cdn/x", documents: dir,
                                              devDefault: lan), lanSlash)
        // an override file still wins
        let file = dir.appendingPathComponent(PayloadBaseURL.overrideFileName)
        try "http://192.168.68.20:9/other/".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(PayloadBaseURL.resolve(manifestBase: "https://cdn/x", documents: dir,
                                              devDefault: lan), "http://192.168.68.20:9/other/")
        // scheme-less file is ignored → baked default, never the CDN placeholder
        try "192.168.68.20:9".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(PayloadBaseURL.resolve(manifestBase: "https://cdn/x", documents: dir,
                                              devDefault: lan), lanSlash)
        // no dev default passed (production call) → manifest base, as before
        XCTAssertEqual(PayloadBaseURL.resolve(manifestBase: "https://cdn/x", documents: dir),
                       "https://cdn/x")
    }
}
