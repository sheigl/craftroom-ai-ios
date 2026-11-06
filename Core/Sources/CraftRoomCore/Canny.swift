import Foundation

/// `canny_edge_v1` — the deterministic device preprocessing recipe
/// (`sdxl/teacher/edge_recipe.py`), reproduced with the exact integer
/// arithmetic OpenCV 4.11 uses, so the iPad produces the same bytes as the
/// frozen training/eval pipeline.
///
/// Recipe (per recipe spec, no adaptive thresholds, no CLAHE):
///
///     gray = round(0.299 R + 0.587 G + 0.114 B)          (ITU-R 601)
///     blur = Gaussian 5x5, sigma 1.4, edge pixels reflect (101)
///     mag  = |Sobel_x| + |Sobel_y|                       (L1, aperture 3)
///     keep = 3x3 non-maximum suppression, hysteresis 100/200
///     mask = 3x3 dilation (1 px growth), values {0, 255}
///
/// Numeric notes — every step is bit-exact to `cv2` on the six fixtures in
/// `Tests/CraftRoomCoreTests/Fixtures/canny` (0 differing pixels):
///
///  * luma: `(9798 R + 19235 G + 3735 B + 16384) >> 15` — OpenCV's SIMD
///    integer coefficients (RY15/GY15/BY15). The scalar float32 path rounds
///    half-to-even and differs by 1 LSB on ~0.03 % of pixels, so the integer
///    form is the one to match (it is also what the 768-wide device images hit).
///  * blur: `cv::GaussianBlur` on CV_8U is a *fixed point* separable filter:
///    kernel [28, 61, 78, 61, 28] (sum 256), horizontal pass accumulates
///    exactly (max 255*256 = 65280), vertical pass rounds with
///    `(sum + 32768) >> 16`, border `BORDER_REFLECT_101` — *not*
///    BORDER_REPLICATE as the recipe docstring says; the docstring is stale
///    and this implementation follows the code, which is what graded every page.
///  * canny: `cv::Canny` (8U, aperture 3, L1) with the integer direction test
///    `|dy| << 15` against `TG22 = 13573` (tan 22.5 deg in 15-bit fixed
///    point), the asymmetric comparisons `m > a && m >= b`, the pixel ring
///    forced to "rejected", and 8-connected stack hysteresis seeded at
///    `mag > high` flowing through `mag > low` — all per
///    `modules/imgproc/src/canny.cpp` (parallelCanny + finalPass).
public enum CannyEdgeV1 {
    /// Gaussian 5x5 sigma 1.4 as 8-bit fixed point (sum == 256).
    public static let kernel: [Int32] = [28, 61, 78, 61, 28]
    /// Fractal shift of `kernel` (ufixedpoint16).
    public static let kernelShift: Int32 = 8
    /// round(tan(22.5 deg) * 2^15).
    public static let tangent22_5: Int32 = 13573
    public static let lowThreshold: Int32 = 100
    public static let highThreshold: Int32 = 200
    public static let dilationRadius: Int = 1

    public enum Error: Swift.Error, Equatable {
        case invalidSize(width: Int, height: Int, count: Int)
    }

    // MARK: - recipe

    /// Full recipe: RGB8 (width * height * 3, row major) -> mask (0 / 255).
    public static func edgeMask(rgb: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        try validate(rgb.count == width * height * 3, width, height)
        let gray = luma(rgb: rgb, width: width, height: height)
        let blurred = gaussian5(gray, width: width, height: height)
        let kept = canny(blurred, width: width, height: height)
        let grown = dilate3(kept, width: width, height: height)
        return grown.map { $0 ? 255 : 0 }
    }

    /// The ControlNet conditioning tensor: `canvas x canvas` three-channel
    /// map, values {0, 1}, content centred and zero-padded (the T5 spatial
    /// contract: the padded band carries no edges). Channel-major
    /// (`[3][canvas][canvas]`), which is what the Core ML input expects.
    public static func conditionPlanes(mask: [UInt8], width: Int, height: Int,
                                       canvas: Int) throws -> [Float16] {
        try validate(mask.count == width * height, width, height)
        guard width <= canvas, height <= canvas else {
            throw Error.invalidSize(width: width, height: height, count: mask.count)
        }
        let x0 = (canvas - width) / 2
        let y0 = (canvas - height) / 2
        var planes = [Float16](repeating: 0, count: 3 * canvas * canvas)
        planes.withUnsafeMutableBufferPointer { out in
            mask.withUnsafeBufferPointer { src in
                for y in 0..<height {
                    let dstRow = (y0 + y) * canvas + x0
                    let srcRow = y * width
                    for x in 0..<width where src[srcRow + x] != 0 {
                        out[dstRow + x] = 1
                        out[canvas * canvas + dstRow + x] = 1
                        out[2 * canvas * canvas + dstRow + x] = 1
                    }
                }
            }
        }
        return planes
    }

    // MARK: - stages

    /// ITU-R 601 luma with OpenCV's integer coefficients.
    public static func luma(rgb: [UInt8], width: Int, height: Int) -> [UInt8] {
        let n = width * height
        var out = [UInt8](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { dst in
            let d = dst.baseAddress!
            rgb.withUnsafeBufferPointer { src in
                let s = src.baseAddress!
                for i in 0..<n {
                    let r: Int32 = Int32(s[3 * i])
                    let g: Int32 = Int32(s[3 * i + 1])
                    let b: Int32 = Int32(s[3 * i + 2])
                    var acc: Int32 = r * 9798
                    acc += g * 19235
                    acc += b * 3735
                    acc += 16384
                    d[i] = UInt8(acc >> 15)
                }
            }
        }
        return out
    }

    /// `cv::GaussianBlur(gray, 5x5, sigma 1.4)` fixed-point separable filter.
    public static func gaussian5(_ gray: [UInt8], width: Int, height: Int) -> [UInt8] {
        let n = width * height
        var mid = [Int32](repeating: 0, count: n)
        let kw = kernel
        mid.withUnsafeMutableBufferPointer { tmp in
            let t = tmp.baseAddress!
            gray.withUnsafeBufferPointer { src in
                let s = src.baseAddress!
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        var acc: Int32 = 0
                        for k in 0..<5 {
                            let sx = reflect101(x + k - 2, width)
                            let px: Int32 = Int32(s[row + sx])
                            acc += kw[k] * px
                        }
                        t[row + x] = acc           // value * 256, max 65280
                    }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { dst in
            let d = dst.baseAddress!
            mid.withUnsafeBufferPointer { tmp in
                let t = tmp.baseAddress!
                for y in 0..<height {
                    for x in 0..<width {
                        var acc: Int32 = 0
                        for k in 0..<5 {
                            let sy = reflect101(y + k - 2, height)
                            let px: Int32 = t[sy * width + x]
                            acc += kw[k] * px
                        }
                        let v: Int32 = (acc + 32768) >> 16
                        d[y * width + x] = UInt8(min(max(v, 0), 255))
                    }
                }
            }
        }
        return out
    }

    /// 3x3 Sobel (BORDER_REPLICATE) and the L1 magnitude `|gx| + |gy|`.
    public static func gradient(_ gray: [UInt8], width: Int,
                                height: Int) -> (gx: [Int32], gy: [Int32], magnitude: [Int32]) {
        let n = width * height
        var gx = [Int32](repeating: 0, count: n)
        var gy = [Int32](repeating: 0, count: n)
        var mag = [Int32](repeating: 0, count: n)
        gx.withUnsafeMutableBufferPointer { gxB in
            gy.withUnsafeMutableBufferPointer { gyB in
                mag.withUnsafeMutableBufferPointer { magB in
                    let gxp = gxB.baseAddress!
                    let gyp = gyB.baseAddress!
                    let magp = magB.baseAddress!
                    gray.withUnsafeBufferPointer { src in
                        let s = src.baseAddress!
                        for y in 0..<height {
                            let yUp: Int = max(y - 1, 0) * width
                            let yDn: Int = min(y + 1, height - 1) * width
                            let row: Int = y * width
                            for x in 0..<width {
                                let xL: Int = max(x - 1, 0)
                                let xR: Int = min(x + 1, width - 1)
                                let upL: Int32 = Int32(s[yUp + xL])
                                let up: Int32 = Int32(s[yUp + x])
                                let upR: Int32 = Int32(s[yUp + xR])
                                let midL: Int32 = Int32(s[row + xL])
                                let midR: Int32 = Int32(s[row + xR])
                                let dnL: Int32 = Int32(s[yDn + xL])
                                let dn: Int32 = Int32(s[yDn + x])
                                let dnR: Int32 = Int32(s[yDn + xR])
                                var dxv: Int32 = upR + 2 * midR + dnR
                                dxv -= (upL + 2 * midL + dnL)
                                var dyv: Int32 = dnL + 2 * dn + dnR
                                dyv -= (upL + 2 * up + upR)
                                let i = row + x
                                gxp[i] = dxv
                                gyp[i] = dyv
                                magp[i] = abs(dxv) + abs(dyv)
                            }
                        }
                    }
                }
            }
        }
        return (gx, gy, mag)
    }

    /// `cv::Canny(gray, 100, 200, L2gradient: false)` — NMS + hysteresis.
    public static func canny(_ gray: [UInt8], width: Int, height: Int,
                             low: Int32 = CannyEdgeV1.lowThreshold,
                             high: Int32 = CannyEdgeV1.highThreshold) -> [Bool] {
        let (gx, gy, mag) = gradient(gray, width: width, height: height)
        // Map values: 0 = candidate (weak, NMS-passed), 1 = rejected,
        // 2 = edge. The one-pixel ring around the image is forced to 1 so
        // hysteresis cannot leak outside, exactly as canny.cpp does.
        var map = [UInt8](repeating: 1, count: width * height)

        @inline(__always) func magAt(_ x: Int, _ y: Int) -> Int32 {
            if x < 0 || y < 0 || x >= width || y >= height { return 0 }
            return mag[y * width + x]
        }

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let m = mag[row + x]
                if m <= low { continue }
                let dxs = gx[row + x]
                let dys = gy[row + x]
                let ax = abs(dxs)
                let ay = abs(dys) << 15
                let tg22x = ax * tangent22_5
                var keep = false
                if ay < tg22x {
                    keep = m > magAt(x - 1, y) && m >= magAt(x + 1, y)
                } else if ay > tg22x + (ax << 16) {
                    keep = m > magAt(x, y - 1) && m >= magAt(x, y + 1)
                } else {
                    let s = (dxs ^ dys) < 0 ? -1 : 1
                    keep = m > magAt(x - s, y - 1) && m > magAt(x + s, y + 1)
                }
                if keep { map[row + x] = m > high ? 2 : 0 }
            }
        }

        // 8-connected stack hysteresis from every strong pixel.
        var stack: [Int32] = []
        for i in 0..<map.count where map[i] == 2 { stack.append(Int32(i)) }
        while let top = stack.popLast() {
            let idx = Int(top)
            let y = idx / width
            let x = idx - y * width
            for dy in -1...1 {
                let ny = y + dy
                if ny < 0 || ny >= height { continue }
                for dx in -1...1 {
                    let nx = x + dx
                    if nx < 0 || nx >= width { continue }
                    let n = ny * width + nx
                    if map[n] == 0 {
                        map[n] = 2
                        stack.append(Int32(n))
                    }
                }
            }
        }
        return map.map { $0 == 2 }
    }

    /// 3x3 square dilation: one pixel of growth, out-of-image treated as 0.
    public static func dilate3(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        mask.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        if src[y * width + x] { dst[y * width + x] = true; continue }
                        var hit = false
                        for dy in -1...1 where !hit {
                            let ny = y + dy
                            if ny < 0 || ny >= height { continue }
                            for dx in -1...1 {
                                let nx = x + dx
                                if nx < 0 || nx >= width { continue }
                                if src[ny * width + nx] { hit = true; break }
                            }
                        }
                        dst[y * width + x] = hit
                    }
                }
            }
        }
        return out
    }

    // MARK: - helpers

    /// `borderInterpolate(p, len, BORDER_REFLECT_101)`.
    @inline(__always)
    public static func reflect101(_ p: Int, _ len: Int) -> Int {
        if len == 1 { return 0 }
        var p = p
        while p < 0 || p >= len {
            p = p < 0 ? -p : 2 * (len - 1) - p
        }
        return p
    }

    private static func validate(_ ok: Bool, _ width: Int, _ height: Int) throws {
        guard ok, width > 0, height > 0 else {
            throw Error.invalidSize(width: width, height: height, count: 0)
        }
    }
}
