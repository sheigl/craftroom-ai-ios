import Foundation

/// Device payload manifest, schema v2 (`device-v2`).
///
/// The v1 manifest carried an absolute `url` per file, which hard-coded the
/// host (HF). v2 keeps the same `{path, size, sha256}` core plus:
///
///  * `urlBase` — one base for every file; `url == urlBase + "/" + path`.
///    T4/T5 override it with `Documents/payload_base_url.txt`, e.g.
///    `http://192.168.68.83:8000/device_v2/payload/`, so a LAN server can
///    serve the same tree the app downloads from the CDN.
///  * `group` per file and `variants` — the UNet has two numerically
///    identical exports (SDPA default, split_einsum alternate); everything
///    else is shared. Only the selected variant is downloaded.
///  * `optional` — files the product path does not need (VAE encoder).
///
/// `device-v1` stays untouched: `PayloadStore` still speaks the v1 manifest
/// for the legacy klein payload, while the v0.5 harness drives this one.
public struct PayloadManifestV2: Codable, Equatable {
    public static let schemaVersion = "device-v2"

    public struct FileEntry: Codable, Equatable {
        public let path: String
        public let size: Int64
        public let sha256: String
        /// `common` (shared by every variant, always downloaded), a variant
        /// group (`sdpa`, `split_einsum`), or `optional` (skipped unless asked).
        public let group: String
    }

    public struct Variant: Codable, Equatable {
        public let model: String
        public let group: String
        public let label: String
    }

    public let version: String
    public let urlBase: String
    public let models: [String]
    public let variants: [String: Variant]
    public let defaultVariant: String
    public let files: [FileEntry]
    public let totalBytes: Int64

    public enum ManifestError: Error, Equatable, CustomStringConvertible {
        case unsupportedVersion(String)
        case noSuchVariant(String)
        case badURL(String)

        public var description: String {
            switch self {
            case .unsupportedVersion(let v): return "payload manifest version \(v) unsupported"
            case .noSuchVariant(let v): return "payload manifest has no variant \(v)"
            case .badURL(let s): return "payload manifest: bad url base \(s)"
            }
        }
    }

    // MARK: selection

    /// Files needed for a variant, in manifest order: the shared group plus
    /// that variant's group. Optional entries are excluded.
    public func entries(forVariant key: String) throws -> [FileEntry] {
        guard let variant = variants[key] else { throw ManifestError.noSuchVariant(key) }
        return files.filter { $0.group == "common" || $0.group == variant.group }
    }

    public func bytes(forVariant key: String) throws -> Int64 {
        try entries(forVariant: key).reduce(0) { $0 + $1.size }
    }

    /// Model directory name of a variant's `.mlmodelc` inside the payload root.
    public func modelDirectory(forVariant key: String) throws -> String {
        guard let variant = variants[key] else { throw ManifestError.noSuchVariant(key) }
        return variant.model
    }

    /// Absolute download URL for one entry against a base (override or default).
    public func url(for entry: FileEntry, base: String? = nil) -> URL? {
        Self.composeURL(base: base ?? urlBase, path: entry.path)
    }

    public static func composeURL(base: String, path: String) -> URL? {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if root.isEmpty { return nil }
        while root.hasSuffix("/") { root.removeLast() }
        var rel = path
        while rel.hasPrefix("/") { rel.removeFirst() }
        return URL(string: root + "/" + rel)
    }

    // MARK: loading

    /// The manifest shipped inside this package (single source of truth for
    /// the app and the tests; generated on the Linux box by
    /// `sdxl/teacher/device_v2/build_app_manifest_v2.py`).
    public static func bundled() throws -> PayloadManifestV2 {
        guard let url = Bundle.module.url(forResource: "device_manifest_v2",
                                         withExtension: "json") else {
            throw ManifestError.badURL("device_manifest_v2.json missing from CraftRoomCore bundle")
        }
        return try decode(try Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> PayloadManifestV2 {
        let m = try JSONDecoder().decode(PayloadManifestV2.self, from: data)
        guard m.version == schemaVersion else {
            throw ManifestError.unsupportedVersion(m.version)
        }
        return m
    }
}

/// Resolves the payload base URL with the T5 LAN override.
///
/// Order: `Documents/payload_base_url.txt` (trimmed, one line) → a baked dev
/// default (LAN server, passed by the app) → the manifest's `urlBase`. The
/// override exists so a device run can be pointed at a local
/// `python3 -m http.server` without rebuilding or re-uploading the 3 GB
/// payload; an empty or scheme-less file is ignored (and reported), never
/// silently treated as a path.
public enum PayloadBaseURL {
    public static let overrideFileName = "payload_base_url.txt"

    /// Trimmed first non-empty line, nil when absent/blank.
    public static func override(in documents: URL,
                                fileName: String = overrideFileName) -> String? {
        let url = documents.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line
    }

    /// The base the downloader must use.
    ///
    /// Priority: `Documents/payload_base_url.txt` → `devDefault` (the baked LAN
    /// server of the v0.5 dev builds — build 8 shipped only the CDN
    /// placeholder, and with no file pushed the download died before it
    /// started) → the manifest's `urlBase`. Every branch logs which base is
    /// active, so `ladder.log`/telemetry always shows where bytes come from.
    public static func resolve(manifestBase: String, documents: URL?,
                               devDefault: String? = nil) -> String {
        let fallback = normalized(devDefault) ?? manifestBase
        if let documents, let raw = override(in: documents) {
            var base = raw
            guard base.contains("://") else {
                DiagnosticsShim.log("payload: ignoring \(overrideFileName) without a scheme: \(raw)")
                return fallback
            }
            if !base.hasSuffix("/") { base += "/" }
            DiagnosticsShim.log("payload: base \(base) (source: \(overrideFileName))")
            return base
        }
        if normalized(devDefault) != nil {
            DiagnosticsShim.log("payload: base \(fallback) (source: baked dev default, "
                                + "no \(overrideFileName))")
            return fallback
        }
        DiagnosticsShim.log("payload: base \(manifestBase) (source: manifest urlBase)")
        return manifestBase
    }

    private static func normalized(_ base: String?) -> String? {
        guard let base, !base.isEmpty else { return nil }
        return base.hasSuffix("/") ? base : base + "/"
    }
}

/// Tiny indirection so CraftRoomCore does not need UIKit/SwiftUI: the app
/// installs its own logger, tests run without one.
public enum DiagnosticsShim {
    public static var sink: ((String) -> Void)?

    public static func log(_ message: String) {
        sink?(message)
    }
}
