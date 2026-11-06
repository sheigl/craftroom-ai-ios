import XCTest
@testable import CraftRoomCore

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// Parity of the Swift `canny_edge_v1` port against the reference masks the
/// Linux box produced with `cv2` (see
/// `sdxl/teacher/device_v2/make_canny_fixtures.py`).
///
/// The target is bit-exact: every stage of the recipe is integer arithmetic
/// that reproduces OpenCV 4.11 exactly (luma via the SIMD coefficients, the
/// fixed-point Gaussian, the canny NMS direction test and hysteresis). The
/// test asserts *zero* differing pixels; `agreement` / `edgeIoU` are computed
/// and printed as the numbers quoted in HANDOFF (the plan's fallback gate is
/// >= 99.5 % agreement and IoU >= 0.99).
final class CannyParityTests: XCTestCase {
    struct Fixture: Decodable {
        let name: String
        let width: Int
        let height: Int
        let edgePixels: Int
        let edgeRatio: Double

        enum CodingKeys: String, CodingKey {
            case name, width, height
            case edgePixels = "edge_pixels"
            case edgeRatio = "edge_ratio"
        }
    }

    struct FixtureIndex: Decodable {
        let fixtures: [Fixture]
    }

    struct LoadedFixture {
        let meta: Fixture
        let rgb: [UInt8]
        let expected: [UInt8]
    }

    // MARK: fixture plumbing

    static var fixtureDirectory: URL? {
        // SwiftPM copies the whole Fixtures directory next to the test bundle.
        guard let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            return nil
        }
        return base.appendingPathComponent("canny", isDirectory: true)
    }

    private func loadIndex() throws -> [Fixture] {
        guard let dir = Self.fixtureDirectory else {
            throw XCTSkip("Fixtures directory missing from the test bundle")
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("fixtures.json"))
        return try JSONDecoder().decode(FixtureIndex.self, from: data).fixtures
    }

    private func load(_ meta: Fixture) throws -> LoadedFixture {
        let dir = Self.fixtureDirectory!
        #if canImport(CoreGraphics)
        let rgb = try Self.decodePNG(dir.appendingPathComponent("in_\(meta.name).png"))
        let mask = try Self.decodePNG(dir.appendingPathComponent("edge_\(meta.name).png"))
        guard let rgbChannel = rgb.channels.first, rgb.channels.count == 3 else {
            throw XCTSkip("unexpected channel count")
        }
        guard let maskChannel = mask.channels.first else { throw XCTSkip("no mask") }
        return LoadedFixture(meta: meta, rgb: rgbChannel, expected: maskChannel)
        #else
        // Linux: the PNG decoder is CoreGraphics-only, so `raw/` holds the same
        // pixels as bare buffers (written by the fixture script for local runs
        // and not committed).
        let raw = dir.appendingPathComponent("raw", isDirectory: true)
        let rgbURL = raw.appendingPathComponent("\(meta.name).rgb8")
        let maskURL = raw.appendingPathComponent("\(meta.name).mask8")
        guard FileManager.default.fileExists(atPath: rgbURL.path),
              FileManager.default.fileExists(atPath: maskURL.path) else {
            throw XCTSkip("raw/\(meta.name).rgb8 missing (Linux run without local fixtures)")
        }
        let rgb = [UInt8](try Data(contentsOf: rgbURL))
        let mask = [UInt8](try Data(contentsOf: maskURL))
        XCTAssertEqual(rgb.count, meta.width * meta.height * 3)
        XCTAssertEqual(mask.count, meta.width * meta.height)
        return LoadedFixture(meta: meta, rgb: rgb, expected: mask)
        #endif
    }

    #if canImport(CoreGraphics)
    struct DecodedImage {
        let channels: [[UInt8]]
        let width: Int
        let height: Int
    }

    /// Decodes an 8-bit PNG into planar 8-bit channels (CoreGraphics).
    static func decodePNG(_ url: URL) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw XCTSkip("cannot decode \(url.lastPathComponent)")
        }
        let w = image.width, h = image.height
        let count = image.colorSpace?.model == .monochrome ? 1 : 4
        var bytes = [UInt8](repeating: 0, count: w * h * count)
        let cs = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * count,
                                  space: cs,
                                  bitmapInfo: count == 1
                                      ? CGImageAlphaInfo.none.rawValue
                                      : CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("no bitmap context for \(url.lastPathComponent)")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The fixture PNGs are single-channel masks (gray) or RGB inputs; the
        // context above always hands back `count` interleaved channels.
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: w * h), count: count)
        for i in 0..<(w * h) {
            for c in 0..<count { planes[c][i] = bytes[i * count + c] }
        }
        return DecodedImage(channels: planes, width: w, height: h)
    }
    #endif

    // MARK: tests

    func testFixturesAreBitExact() throws {
        let fixtures = try loadIndex()
        XCTAssertEqual(fixtures.count, 6, "expected the six v0.5 fixtures")
        var worstAgreement = 1.0
        var worstIoU = 1.0
        for meta in fixtures {
            let fixture = try load(meta)
            let mask = try CannyEdgeV1.edgeMask(rgb: fixture.rgb,
                                                width: meta.width, height: meta.height)
            XCTAssertEqual(mask.count, meta.width * meta.height)

            var differing = 0
            var intersection = 0
            var union = 0
            var produced = 0
            for i in 0..<mask.count {
                let a = mask[i] != 0
                let b = fixture.expected[i] != 0
                if a { produced += 1 }
                if a != b { differing += 1 }
                if a || b {
                    union += 1
                    if a && b { intersection += 1 }
                }
            }
            let agreement = 1.0 - Double(differing) / Double(mask.count)
            let iou = union == 0 ? 1.0 : Double(intersection) / Double(union)
            worstAgreement = min(worstAgreement, agreement)
            worstIoU = min(worstIoU, iou)
            print("canny \(meta.name) \(meta.width)x\(meta.height)"
                  + " pixels \(mask.count) edges \(produced)/\(meta.edgePixels)"
                  + String(format: " disagreement %d agreement %.6f iou %.6f",
                           differing, agreement, iou))
            XCTAssertGreaterThanOrEqual(agreement, 0.995,
                                        "\(meta.name): pixel agreement below the gate")
            XCTAssertGreaterThanOrEqual(iou, 0.99, "\(meta.name): edge IoU below the gate")
            XCTAssertEqual(differing, 0, "\(meta.name): expected bit-exact parity with cv2")
        }
        print(String(format: "canny parity worst: agreement %.6f iou %.6f",
                     worstAgreement, worstIoU))
    }

    func testDeterministic() throws {
        let meta = try XCTUnwrap(try loadIndex().first)
        let fixture = try load(meta)
        let a = try CannyEdgeV1.edgeMask(rgb: fixture.rgb, width: meta.width, height: meta.height)
        let b = try CannyEdgeV1.edgeMask(rgb: fixture.rgb, width: meta.width, height: meta.height)
        XCTAssertEqual(a, b)
    }

    func testBlankImageHasNoEdges() {
        let w = 96, h = 64
        let rgb = [UInt8](repeating: 200, count: w * h * 3)
        let mask = try! CannyEdgeV1.edgeMask(rgb: rgb, width: w, height: h)
        XCTAssertFalse(mask.contains { $0 != 0 }, "a flat image must produce no edges")
    }

    func testSinglePixelDilatesToThreeByThree() {
        let w = 9, h = 9
        var kept = [Bool](repeating: false, count: w * h)
        kept[4 * w + 4] = true
        let grown = CannyEdgeV1.dilate3(kept, width: w, height: h)
        for y in 3...5 {
            for x in 3...5 {
                XCTAssertTrue(grown[y * w + x], "dilation must cover the 3x3 neighbourhood")
            }
        }
        XCTAssertEqual(grown.filter { $0 }.count, 9, "1 px growth only")
    }

    func testConditionPlanesZeroPadAndCentre() throws {
        let w = 4, h = 2
        var mask = [UInt8](repeating: 0, count: w * h)
        mask[0] = 255                      // top-left of the content
        let canvas = 8
        let planes = try CannyEdgeV1.conditionPlanes(mask: mask, width: w, height: h,
                                                     canvas: canvas)
        XCTAssertEqual(planes.count, 3 * canvas * canvas)
        let x0 = (canvas - w) / 2, y0 = (canvas - h) / 2
        let expected = y0 * canvas + x0
        for c in 0..<3 {
            XCTAssertEqual(planes[c * canvas * canvas + expected], 1)
        }
        XCTAssertEqual(planes.reduce(0) { $0 + ($1 == 1 ? 1 : 0) }, 3,
                       "only the one edge pixel is set, in all three planes")
    }

    func testReflect101MatchesOpenCVBorder() {
        XCTAssertEqual(CannyEdgeV1.reflect101(-1, 10), 1)
        XCTAssertEqual(CannyEdgeV1.reflect101(-2, 10), 2)
        XCTAssertEqual(CannyEdgeV1.reflect101(10, 10), 8)
        XCTAssertEqual(CannyEdgeV1.reflect101(11, 10), 7)
        XCTAssertEqual(CannyEdgeV1.reflect101(-1, 1), 0)
        XCTAssertEqual(CannyEdgeV1.reflect101(0, 10), 0)
    }

    func testRejectsInconsistentBuffers() {
        XCTAssertThrowsError(try CannyEdgeV1.edgeMask(rgb: [0, 0, 0], width: 4, height: 4))
    }
}
