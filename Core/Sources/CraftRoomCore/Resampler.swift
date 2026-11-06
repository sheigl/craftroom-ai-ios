import Foundation

/// Deterministic Lanczos-3 resampling for the device preprocessing path.
///
/// The T5 spatial contract resizes the source to long edge 768 with LANCZOS.
/// CoreGraphics' `.high` interpolation is an unspecified filter, so the
/// pipeline uses this explicit kernel instead: same code on device and in
/// `swift test`, no float32-vs-CoreGraphics ambiguity, and the semantics are
/// documented here rather than hidden in a framework:
///
///  * separable, 3-lobe windowed sinc, `kernel(x) = sinc(x) * sinc(x / 3)`;
///  * downscaling widens the support (`support = 3 * max(1, src / dst)`) so
///    every source pixel contributes — no aliasing at 4000 px → 768 px;
///  * weights are normalised per output pixel (so constants survive exactly),
///    source indices clamp to the edge;
///  * one rounding to 8 bit per channel at the end.
///
/// The parity gate of the recipe is on the *post-resize* pixels (the reference
/// fixtures are already at device dims), so this filter only decides which
/// pixels `canny_edge_v1` sees — it is not compared against PIL.
public enum Resampler {
    /// Lanczos-3 windowed sinc, 0 outside |x| < 3.
    public static func kernel(_ x: Double) -> Double {
        let a = abs(x)
        if a < 1e-12 { return 1 }
        if a >= 3 { return 0 }
        let px = Double.pi * a
        return (sin(px) / px) * (sin(px / 3) / (px / 3))
    }

    /// Weight table for one output axis: taps and normalised weights.
    public static func weights(srcLength: Int, dstLength: Int)
        -> [[(index: Int, weight: Float)]] {
        guard srcLength > 0, dstLength > 0 else { return [] }
        let scale = Double(srcLength) / Double(dstLength)
        let filterScale = max(1.0, scale)
        let support = 3.0 * filterScale
        var table: [[(Int, Float)]] = []
        table.reserveCapacity(dstLength)
        for i in 0..<dstLength {
            let center = (Double(i) + 0.5) * scale - 0.5
            let lo = Int((center - support).rounded(.down))
            let hi = Int((center + support).rounded(.up))
            var taps: [(Int, Double)] = []
            var sum = 0.0
            for t in lo...hi {
                let w = kernel((Double(t) - center) / filterScale)
                if w == 0 { continue }
                taps.append((min(max(t, 0), srcLength - 1), w))
                sum += w
            }
            if sum == 0 {
                taps = [(min(max(Int(center.rounded()), 0), srcLength - 1), 1)]
                sum = 1
            }
            table.append(taps.map { ($0.0, Float($0.1 / sum)) })
        }
        return table
    }

    /// RGB8 (width * height * 3, row major) -> RGB8 at the destination size.
    public static func lanczos3(rgb: [UInt8], srcWidth: Int, srcHeight: Int,
                                dstWidth: Int, dstHeight: Int) -> [UInt8] {
        guard srcWidth > 0, srcHeight > 0, dstWidth > 0, dstHeight > 0 else { return [] }
        if srcWidth == dstWidth && srcHeight == dstHeight { return rgb }
        let hTaps = weights(srcLength: srcWidth, dstLength: dstWidth)
        let vTaps = weights(srcLength: srcHeight, dstLength: dstHeight)

        // horizontal pass: dstWidth x srcHeight
        var mid = [Float](repeating: 0, count: dstWidth * srcHeight * 3)
        rgb.withUnsafeBufferPointer { src in
            for y in 0..<srcHeight {
                let srcRow = y * srcWidth * 3
                let dstRow = y * dstWidth * 3
                for x in 0..<dstWidth {
                    let taps = hTaps[x]
                    var r: Float = 0, g: Float = 0, b: Float = 0
                    for tap in taps {
                        let o = srcRow + tap.index * 3
                        r += tap.weight * Float(src[o])
                        g += tap.weight * Float(src[o + 1])
                        b += tap.weight * Float(src[o + 2])
                    }
                    let d = dstRow + x * 3
                    mid[d] = r
                    mid[d + 1] = g
                    mid[d + 2] = b
                }
            }
        }

        // vertical pass + 8-bit rounding
        var out = [UInt8](repeating: 0, count: dstWidth * dstHeight * 3)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<dstHeight {
                let taps = vTaps[y]
                let dstRow = y * dstWidth * 3
                for x in 0..<dstWidth {
                    var r: Float = 0, g: Float = 0, b: Float = 0
                    for tap in taps {
                        let o = tap.index * dstWidth * 3 + x * 3
                        r += tap.weight * mid[o]
                        g += tap.weight * mid[o + 1]
                        b += tap.weight * mid[o + 2]
                    }
                    let d = dstRow + x * 3
                    dst[d] = clamp8(r)
                    dst[d + 1] = clamp8(g)
                    dst[d + 2] = clamp8(b)
                }
            }
        }
        return out
    }

    @inline(__always)
    private static func clamp8(_ v: Float) -> UInt8 {
        UInt8(min(max(v.rounded(), 0), 255))
    }
}
