import XCTest
@testable import CraftRoomCore

/// The pipeline's own resize (long edge 768, aspect preserved) is Lanczos-3
/// implemented here, so it is testable and identical on every platform.
final class ResamplerTests: XCTestCase {
    func testKernelShape() {
        XCTAssertEqual(Resampler.kernel(0), 1, accuracy: 1e-12)
        XCTAssertEqual(Resampler.kernel(1), 0, accuracy: 1e-9)
        XCTAssertEqual(Resampler.kernel(2), 0, accuracy: 1e-9)
        XCTAssertEqual(Resampler.kernel(3), 0, accuracy: 1e-12)
        XCTAssertEqual(Resampler.kernel(3.5), 0, accuracy: 1e-12)
        XCTAssertEqual(Resampler.kernel(-1), 0, accuracy: 1e-9)
    }

    func testWeightsAreNormalisedAndInBounds() {
        for (src, dst) in [(768, 576), (576, 768), (4000, 768), (100, 768)] {
            let table = Resampler.weights(srcLength: src, dstLength: dst)
            XCTAssertEqual(table.count, dst)
            for taps in table {
                XCTAssertFalse(taps.isEmpty)
                let sum = taps.reduce(Float(0)) { $0 + $1.weight }
                XCTAssertEqual(sum, 1, accuracy: 1e-5)
                for tap in taps {
                    XCTAssertTrue((0..<src).contains(tap.index), "source index in range")
                }
            }
        }
    }

    func testIdentityReturnsInputUnchanged() {
        let w = 7, h = 5
        let rgb = (0..<(w * h * 3)).map { UInt8($0 % 251) }
        XCTAssertEqual(Resampler.lanczos3(rgb: rgb, srcWidth: w, srcHeight: h,
                                          dstWidth: w, dstHeight: h), rgb)
    }

    func testFlatFieldSurvivesExactly() {
        let w = 40, h = 30, dw = 19, dh = 13
        let rgb = [UInt8](repeating: 137, count: w * h * 3)
        let out = Resampler.lanczos3(rgb: rgb, srcWidth: w, srcHeight: h,
                                     dstWidth: dw, dstHeight: dh)
        XCTAssertEqual(out.count, dw * dh * 3)
        XCTAssertTrue(out.allSatisfy { $0 == 137 }, "normalised weights must preserve constants")
    }

    func testDownscaleKeepsAStepEdgeMonotoneAndInRange() {
        let w = 200, h = 8, dw = 50, dh = 4
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in (w / 2)..<w {
                for c in 0..<3 { rgb[(y * w + x) * 3 + c] = 255 }
            }
        }
        let out = Resampler.lanczos3(rgb: rgb, srcWidth: w, srcHeight: h,
                                     dstWidth: dw, dstHeight: dh)
        let row = (0..<dw).map { out[((dh / 2) * dw + $0) * 3] }
        // flat regions stay flat, the transition is a short ramp
        XCTAssertEqual(row.first, 0)
        XCTAssertEqual(row.last, 255)
        let intermediate = row.filter { $0 != 0 && $0 != 255 }
        XCTAssertLessThanOrEqual(intermediate.count, 8,
                                 "a 4x downscale of a hard step must be a short ramp")
        XCTAssertGreaterThanOrEqual(intermediate.count, 1, "the step must be resolved")
        for i in 1..<row.count {
            XCTAssertGreaterThanOrEqual(Int(row[i]), Int(row[i - 1]) - 1,
                                        "the ramp must be monotone (row \(row))")
        }
        XCTAssertTrue(intermediate.allSatisfy { (1...254).contains($0) })
    }
}
