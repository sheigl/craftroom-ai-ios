import UIKit
import CraftRoomCore

/// Image <-> buffer plumbing for the v0.5 pipeline.
///
/// The source is read once at its native resolution, resized with the
/// pipeline's own Lanczos-3 (`CraftRoomCore.Resampler`) to long edge 768 with
/// the aspect preserved, and handed to the canny recipe as RGB8. Output comes
/// back as the VAE's planar fp32 `[-1, 1]` RGB, cropped to the content rect.
///
/// Memory note: a 48 MP import is decoded at native size (≈195 MB for the
/// bitmap) but resized in ONE pass and released immediately, before the 2.87 GB
/// UNet is touched, so peak footprint stays at the weights + one 768² frame.
enum ImageUtils {
    struct Source {
        let rgb: [UInt8]
        let width: Int
        let height: Int
    }

    /// Upright RGB8 at long edge `Spatial.longEdge`, aspect preserved.
    static func rgbAtLongEdge(_ image: UIImage,
                              longEdge: Int = Spatial.longEdge) throws -> Source {
        let native = try rgb8(image)
        let target = Spatial.contentSize(sourceWidth: native.width,
                                        sourceHeight: native.height,
                                        longEdge: longEdge)
        let resized = Resampler.lanczos3(rgb: native.rgb,
                                        srcWidth: native.width, srcHeight: native.height,
                                        dstWidth: target.width, dstHeight: target.height)
        Diagnostics.log("resize: \(native.width)x\(native.height) → "
                        + "\(target.width)x\(target.height) (lanczos3)")
        return Source(rgb: resized, width: target.width, height: target.height)
    }

    /// Upright RGB8 at native size (EXIF orientation baked in).
    static func rgb8(_ image: UIImage) throws -> Source {
        let iw = Int(image.size.width.rounded()), ih = Int(image.size.height.rounded())
        guard iw > 0, ih > 0 else { throw PipError.image("zero-size image") }
        guard let cg = image.cgImage else { throw PipError.image("no CGImage") }
        var bytes = [UInt8](repeating: 0, count: iw * ih * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: iw, height: ih,
                                  bitsPerComponent: 8, bytesPerRow: iw * 4,
                                  space: cs,
                                  bitmapInfo: [.byteOrder32Little,
                                               CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]) else {
            throw PipError.image("no bitmap context")
        }
        // CGContext draws bottom-up; the CGImage path with an upright image
        // lands the orientation correctly for UIImage(scale: 1, orientation: .up)
        // sources, which is what the picker and the bundled test photo are.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(iw), height: CGFloat(ih)))
        var rgb = [UInt8](repeating: 0, count: iw * ih * 3)
        let n = iw * ih
        for i in 0..<n {
            let o = i * 4
            rgb[i * 3] = bytes[o + 2]        // R (byteOrder32Little ⇒ B,G,R,A)
            rgb[i * 3 + 1] = bytes[o + 1]    // G
            rgb[i * 3 + 2] = bytes[o]        // B
        }
        return Source(rgb: rgb, width: iw, height: ih)
    }

    /// VAE output (planar fp32, `[-1, 1]`, `canvas²`) -> UIImage cropped to the
    /// content rect that the edge map occupied.
    static func uiImage(rgbPlanar planar: [Float], canvas: Int,
                        contentWidth: Int, contentHeight: Int) throws -> UIImage {
        let plane = canvas * canvas
        guard planar.count >= 3 * plane else {
            throw PipError.model("decoder out \(planar.count) < \(3 * plane)")
        }
        let rect = Spatial.cropRect(width: contentWidth, height: contentHeight, canvas: canvas)
        let w = rect.width, h = rect.height
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        func ch8(_ v: Float) -> UInt8 {
            let s = max(0, min(1, (v + 1) * 0.5))
            return UInt8((s * 255).rounded())
        }
        for y in 0..<h {
            let srcRow = (rect.y + y) * canvas + rect.x
            let dstRow = y * w
            for x in 0..<w {
                let src = srcRow + x
                let dst = (dstRow + x) * 4
                bytes[dst] = ch8(planar[2 * plane + src])      // B
                bytes[dst + 1] = ch8(planar[plane + src])      // G
                bytes[dst + 2] = ch8(planar[src])              // R
            }
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: [.byteOrder32Little,
                                               CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]),
              let cg = ctx.makeImage() else {
            throw PipError.image("no output bitmap")
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// PNG bytes of a rendered page (the export path used after a run).
    static func pngData(_ image: UIImage) -> Data? {
        image.pngData()
    }
}
