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
        XCTAssertEqual(Set(m.variants.keys), ["sdpa", "split_einsum"])
        XCTAssertTrue(m.urlBase.hasPrefix("https://"),
                      "the default base must be the published payload, not a LAN address")
        XCTAssertEqual(m.files.count, 18, "2 UNet trees x 5 files + VAE decoder 5 + 3 embeds")
        for f in m.files {
            XCTAssertEqual(f.sha256.count, 64, "\(f.path): sha256 must be hex-64")
            XCTAssertTrue(f.sha256.allSatisfy { $0.isHexDigit })
            XCTAssertGreaterThan(f.size, 0)
            XCTAssertFalse(f.path.hasPrefix("/"), "paths must be relative to urlBase")
            XCTAssertTrue(["common", "sdpa", "split_einsum"].contains(f.group),
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
}
