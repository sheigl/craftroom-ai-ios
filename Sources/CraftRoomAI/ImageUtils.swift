import UIKit

/// Center-crop to the 3:2 reference aspect, bake EXIF orientation, rescale to
/// 1248x832, and hand the VAE [-1,1] CHW floats.
enum ImageUtils {
    static func normalizedPixels(_ image: UIImage) throws -> [Float] {
        // 1. bake orientation (EXIF) into upright pixels at native size
        let native = image.size
        guard native.width > 0, native.height > 0 else {
            throw PipError.image("zero-size image")
        }
        let fmt = UIGraphicsImageFormat()
        fmt.size = native
        fmt.opaque = true
        let upright = UIGraphicsImageRenderer(format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: native))
        }
        guard let src = upright.cgImage else { throw PipError.image("no CGImage") }

        // 2. center-crop to 1248:832
        let aspect = CGFloat(Geo.photoW) / CGFloat(Geo.photoH)
        let srcW = CGFloat(src.width), srcH = CGFloat(src.height)
        var cropW = srcW, cropH = srcH
        if srcW / srcH > aspect { cropW = srcH * aspect } else { cropH = srcW / aspect }
        let cropRect = CGRect(x: (srcW - cropW) / 2, y: (srcH - cropH) / 2,
                              width: cropW, height: cropH)
        guard let cropped = src.cropping(to: cropRect) else {
            throw PipError.image("crop failed")
        }

        // 3. rescale to the export shape
        let w = Geo.photoW, h = Geo.photoH
        guard let cs = CGColorSpace(name: .sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: [.byteOrder32BitLittle, .alphaNoneMask]) else {
            throw PipError.image("no context")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let scaled = ctx.makeImage(), let cfData = scaled.dataProvider?.copyData() else {
            throw PipError.image("scale failed")
        }
        let bytes = [UInt8](cfData as Data)   // row-major, B,G,R,A (32BitLittle)
        guard bytes.count >= w * h * 4 else { throw PipError.image("short bitmap") }

        // 4. CHW, [-1,1]
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
