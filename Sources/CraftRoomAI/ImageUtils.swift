import UIKit

/// Aspect-fill crop to the 3:2 reference aspect, bake EXIF orientation, rescale
/// to 1248x832 — in ONE draw — and hand the VAE [-1,1] CHW floats.
enum ImageUtils {
    static func normalizedPixels(_ image: UIImage) throws -> [Float] {
        let w = Geo.photoW, h = Geo.photoH
        let iw = image.size.width, ih = image.size.height
        guard iw > 0, ih > 0 else {
            throw PipError.image("zero-size image")
        }

        // ONE draw at the target size: centre aspect-fill + EXIF bake +
        // downscale. The earlier path first rendered the photo at its NATIVE
        // size (a 48 MP import = ~195 MB, then a second crop copy), which
        // jetsam-killed the app as soon as the 3.7 GB int8 DiT was resident —
        // large photos crashed, small ones survived. This costs ~4 MB for any
        // input, so photo size no longer affects peak memory.
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = true
        let scale = max(CGFloat(w) / iw, CGFloat(h) / ih)
        let dw = iw * scale, dh = ih * scale
        let upright = UIGraphicsImageRenderer(size: CGSize(width: w, height: h),
                                             format: fmt).image { _ in
            image.draw(in: CGRect(x: (CGFloat(w) - dw) / 2,
                                  y: (CGFloat(h) - dh) / 2,
                                  width: dw, height: dh))
        }
        guard let src = upright.cgImage else { throw PipError.image("no CGImage") }

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: [.byteOrder32Little,
                                               CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]) else {
            throw PipError.image("no context")
        }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let raw = ctx.data else { throw PipError.image("scale failed") }
        let bytes = [UInt8](UnsafeBufferPointer(
            start: raw.bindMemory(to: UInt8.self, capacity: w * h * 4), count: w * h * 4))
        guard bytes.count >= w * h * 4 else { throw PipError.image("short bitmap") }

        // CHW, [-1,1]
        let wh = w * h
        var chw = [Float](repeating: 0, count: 3 * wh)
        for i in 0..<wh {
            let o = i * 4
            chw[wh + i]        = Float(bytes[o + 1]) / 127.5 - 1  // G
            chw[2 * wh + i]    = Float(bytes[o + 0]) / 127.5 - 1  // B
            chw[i]             = Float(bytes[o + 2]) / 127.5 - 1  // R
        }
        return chw
    }
}
