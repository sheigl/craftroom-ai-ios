import Foundation

/// Errors surfaced by the harness (payload, model, image, resource).
///
/// The FLUX.2-klein geometry that used to live here (`Geo`) went with the klein
/// pipeline; the v0.5 numbers are in `CraftRoomCore` (`Spatial`) instead.
enum PipError: Error, LocalizedError {
    case missingResource(String)
    case badPayload(String)
    case model(String)
    case image(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let n): return "missing bundled resource: \(n)"
        case .badPayload(let m):      return "payload invalid: \(m)"
        case .model(let m):           return "model error: \(m)"
        case .image(let m):           return "image error: \(m)"
        }
    }
}
