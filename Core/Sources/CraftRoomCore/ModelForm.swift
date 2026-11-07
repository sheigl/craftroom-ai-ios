import Foundation

/// How a manifest ships one model, and where an on-device compile would cache.
///
/// Default is `mlmodelc`: `.mlmodelc` trees compiled by the GitHub macOS runner
/// (the only build host), downloaded and handed straight to
/// `MLModel(contentsOf:)`. That is what the served `device-v2` manifest does,
/// and nothing about it changes here.
///
/// `mlpackage` is build 10's **plan B** for hypothesis B (a macOS-compiled
/// `.mlmodelc` refusing to load on iOS): ship the `.mlpackage` source instead
/// and let the device compile it once with `MLModel.compileModel(at:)`, which
/// runs on iOS itself. The `.mlpackage` dirs already exist on the payload host
/// (`packages/…`, `device_v2/vae/…`), so flipping a manifest entry's `form` is
/// the whole server-side change. The app-side decision and cache naming are
/// pure functions so they are unit-testable without Core ML.
public enum ModelForm: String, Codable, Equatable {
    /// compiled Core ML directory, load directly (default)
    case mlmodelc
    /// Core ML source package, compile once on device then load the cache
    case mlpackage

    public var needsDeviceCompile: Bool { self == .mlpackage }
}

public enum DeviceCompileCache {
    /// Directory (inside Caches) a device-compiled model is cached in:
    /// `<model-basename>-<content-key>.mlmodelc`.
    ///
    /// `contentKey` is a short stable hash of the model's file list (see
    /// `contentKey(for:)`), so re-baking a model invalidates the cache and a
    /// partial/corrupt compile never gets reused as if it were the new model.
    /// This is a cache key, not a security digest — FNV-1a, no CryptoKit, so it
    /// also works on Linux where the tests run.
    public static func cacheDirectoryName(model: String, contentKey: String) -> String {
        let base = model.hasSuffix(".mlmodelc") ? String(model.dropLast(".mlmodelc".count))
            : model.hasSuffix(".mlpackage") ? String(model.dropLast(".mlpackage".count))
            : model
        let safe = String(base.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
            ? $0 : "-" })
        return "\(safe)-\(contentKey).mlmodelc"
    }

    /// Stable key over a model's files: FNV-1a-64 over sorted `path:size:sha`.
    public static func contentKey(paths: [String], sizes: [Int64], sha256s: [String]) -> String {
        precondition(paths.count == sizes.count && sizes.count == sha256s.count)
        var rows: [String] = []
        for i in paths.indices {
            rows.append("\(paths[i]):\(sizes[i]):\(sha256s[i])")
        }
        rows.sort()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rows.joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Same thing straight from manifest entries (the app's call site).
    public static func contentKey(for entries: [PayloadManifestV2.FileEntry],
                                  modelDirectory: String) -> String {
        let dir = modelDirectory.hasSuffix("/") ? modelDirectory : modelDirectory + "/"
        let files = entries.filter { $0.path.hasPrefix(dir) }
        return contentKey(paths: files.map(\.path),
                          sizes: files.map(\.size),
                          sha256s: files.map(\.sha256))
    }
}
