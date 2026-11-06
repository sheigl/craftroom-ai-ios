import Foundation

/// The spatial contract of the fixed 768² graph (plan §"T5 spatial contract",
/// 2026-11-06):
///
///  1. resize the source to long edge 768, aspect preserved (LANCZOS);
///  2. compute `canny_edge_v1` at that size;
///  3. zero-pad the edge map into 768x768, content centred;
///  4. sample 30 steps Euler at CFG 9, decode 768x768;
///  5. crop the result back to the same rect.
///
/// The padded band carries *no* edges, so the model is not told to draw a
/// border; the crop discards the band again.
public enum Spatial {
    /// Fixed pixel size of the exported graph (and of `controlnet_cond`).
    public static let canvas: Int = 768
    /// Fixed latent side of the exported graph.
    public static let latentSide: Int = 96
    /// VAE downsampling factor (768 / 96).
    public static let latentScale: Int = 8
    /// Long edge the source is resized to before canny.
    public static let longEdge: Int = 768
    /// Contract §3 / A2: CFG 9.0 (`eps = neg + 9 * (pos - neg)`).
    public static let guidanceScale: Float = 9.0
    /// Diffusers defaults for the frozen eval.
    public static let defaultSteps: Int = 30
    /// `time_ids` = `[H_b, W_b, 0, 0, H_b, W_b]` — orig == target == bucket,
    /// exactly as every graded page scored (contract §5.2 parity note). The
    /// true photo size is deliberately *not* used.
    public static let timeIds: [Float16] = [768, 768, 0, 0, 768, 768]

    /// Long-edge resize with aspect preserved; never returns a zero side.
    public static func contentSize(sourceWidth: Int, sourceHeight: Int,
                                   longEdge: Int = Spatial.longEdge) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (longEdge, longEdge) }
        if sourceWidth >= sourceHeight {
            let w = longEdge
            let h = max(1, Int((Double(sourceHeight) * Double(longEdge) / Double(sourceWidth)).rounded()))
            return (w, h)
        }
        let h = longEdge
        let w = max(1, Int((Double(sourceWidth) * Double(longEdge) / Double(sourceHeight)).rounded()))
        return (w, h)
    }

    /// Top-left offset of the content inside the square canvas (centred).
    public static func padding(width: Int, height: Int,
                              canvas: Int = Spatial.canvas) -> (x: Int, y: Int) {
        (x: max(0, (canvas - min(width, canvas)) / 2),
         y: max(0, (canvas - min(height, canvas)) / 2))
    }

    /// Crop rect of the decoded canvas that corresponds to the content.
    public static func cropRect(width: Int, height: Int,
                                canvas: Int = Spatial.canvas) -> (x: Int, y: Int, width: Int, height: Int) {
        let p = padding(width: width, height: height, canvas: canvas)
        return (p.x, p.y, min(width, canvas), min(height, canvas))
    }
}
