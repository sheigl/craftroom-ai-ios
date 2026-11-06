import XCTest
@testable import CraftRoomCore

/// The T5 spatial contract: long edge 768, aspect preserved, zero-padded edge
/// map, output cropped back to the content rect.
final class SpatialTests: XCTestCase {
    func testLongEdgeResizePreservesAspect() {
        let cases: [(Int, Int, Int, Int)] = [
            (4000, 3000, 768, 576),     // 4:3 landscape
            (3000, 4000, 576, 768),     // 3:4 portrait
            (1126, 2000, 432, 768),     // the bundled test photo, 9:16
            (2000, 1126, 768, 432),     // 16:9
            (1000, 1000, 768, 768),     // square
            (6000, 500, 768, 64),       // extreme landscape
            (500, 6000, 64, 768),       // extreme portrait
        ]
        for (sw, sh, ew, eh) in cases {
            let got = Spatial.contentSize(sourceWidth: sw, sourceHeight: sh)
            XCTAssertEqual(got.width, ew, "width for \(sw)x\(sh)")
            XCTAssertEqual(got.height, eh, "height for \(sw)x\(sh)")
            XCTAssertEqual(max(got.width, got.height), Spatial.longEdge)
            let srcAspect = Double(sw) / Double(sh)
            let dstAspect = Double(got.width) / Double(got.height)
            XCTAssertLessThan(abs(srcAspect - dstAspect) / srcAspect, 0.01,
                              "aspect must be preserved for \(sw)x\(sh)")
        }
    }

    func testDegenerateInputNeverProducesZeroSides() {
        let got = Spatial.contentSize(sourceWidth: 0, sourceHeight: 0)
        XCTAssertEqual(got.width, Spatial.longEdge)
        XCTAssertEqual(got.height, Spatial.longEdge)
        let thin = Spatial.contentSize(sourceWidth: 1, sourceHeight: 5000)
        XCTAssertGreaterThanOrEqual(thin.width, 1)
        XCTAssertEqual(thin.height, Spatial.longEdge)
    }

    func testPaddingCentresAndCropInvertsIt() {
        for (w, h) in [(768, 576), (432, 768), (768, 768), (500, 700)] {
            let p = Spatial.padding(width: w, height: h)
            XCTAssertEqual(p.x, (768 - w) / 2)
            XCTAssertEqual(p.y, (768 - h) / 2)
            XCTAssertGreaterThanOrEqual(p.x, 0)
            XCTAssertGreaterThanOrEqual(p.y, 0)
            XCTAssertLessThanOrEqual(p.x + w, 768)
            XCTAssertLessThanOrEqual(p.y + h, 768)
            let r = Spatial.cropRect(width: w, height: h)
            XCTAssertEqual(r.x, p.x)
            XCTAssertEqual(r.y, p.y)
            XCTAssertEqual(r.width, w)
            XCTAssertEqual(r.height, h)
        }
    }

    func testContractConstants() {
        XCTAssertEqual(Spatial.canvas, 768)
        XCTAssertEqual(Spatial.latentSide, 96)
        XCTAssertEqual(Spatial.latentScale, 8)
        XCTAssertEqual(Spatial.canvas / Spatial.latentScale, Spatial.latentSide)
        XCTAssertEqual(Spatial.guidanceScale, 9.0)
        XCTAssertEqual(Spatial.defaultSteps, 30)
        XCTAssertEqual(Spatial.timeIds, [768, 768, 0, 0, 768, 768])
        XCTAssertEqual(Spatial.timeIds.count, 6)
    }
}
