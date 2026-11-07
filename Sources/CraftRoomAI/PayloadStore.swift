import Foundation
import CryptoKit
import UIKit
import CraftRoomCore

/// One downloadable file of the **legacy** `device-v1` payload (klein). Kept
/// so the v0.4 store still compiles and can still serve an old bundle; the
/// v0.5 harness uses `PayloadManifestV2` from CraftRoomCore.
struct DeviceFile: Codable {
    let path: String
    let size: Int64
    let sha256: String
    let url: String
}

struct DeviceManifest: Codable {
    let version: String
    let models: [String]
    let files: [DeviceFile]
    let totalBytes: Int64
}

enum PayloadState: Equatable {
    case checking
    case ready
    /// payload not installed; totalMB is the whole download
    case missing(totalMB: Int64)
    case downloading(fraction: Double, doneMB: Int64, totalMB: Int64)
    case failed(String)
}

/// Device-v2 payload store (v0.5).
///
/// Downloads the compiled `.mlmodelc` trees and embed bins declared by
/// `CraftRoomCore`'s `device_manifest_v2.json` into
/// `Application Support/CraftRoomPayload/`, one file at a time:
///
///  * **base URL** — `Documents/payload_base_url.txt` (one line) wins; else
///    the baked dev default `http://192.168.68.83:8123/device_v2/payload/`
///    (LAN server, build 9+); else the manifest's CDN base. The active base
///    is logged ("payload: base ... source ..."). T5 needs no file push.
///  * **variant** — `sdpa` (default) or `split_einsum`; only that 2.87 GB UNet
///    subtree plus the shared files is fetched, so switching attention layouts
///    costs one model, not a second payload.
///  * **resume** — a `.part` file is appended to across attempts with an HTTP
///    `Range` request; if the server answers `200` instead of `206` the file
///    restarts (python's `http.server` does not implement ranges).
///  * **integrity** — size then sha256 per file, before it is moved into place.
///
/// The model weights no longer ride in the ipa (ITMS-90558: 4 GB thinned-bundle
/// cap), which is why this store is the first-launch path.
final class PayloadStore: NSObject, URLSessionDataDelegate {
    static let shared = PayloadStore()

    let root: URL
    /// Legacy device-v1 manifest, if a bundle still ships one.
    private(set) var manifest: DeviceManifest?
    /// The v0.5 manifest.
    private(set) var manifestV2: PayloadManifestV2?

    private var session: URLSession!
    private var variantKey: String = "sdpa"
    private var base: String = ""
    private var pendingTask: URLSessionDataTask?
    private var pendingContinuation: CheckedContinuation<Void, Error>?
    private var pendingHandle: FileHandle?
    private var pendingExpectation: (path: String, url: URL)?
    private var liveBytes: Int64 = 0
    private var settledBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private let defaults = UserDefaults.standard
    private static let variantDefaultsKey = "payload.variant"

    /// Baked dev default for the v0.5 T5 runs (build 9): the LAN payload
    /// server. Used only when `Documents/payload_base_url.txt` is absent, so
    /// a pushed file still overrides it and a production build can restore the
    /// manifest base by passing nil. Build 8 shipped without this and, with no
    /// file pushed, tried the unbaked HF placeholder and died.
    static let devLANBase = "http://192.168.68.83:8123/device_v2/payload/"

    private override init() {
        let baseDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = baseDir.appendingPathComponent("CraftRoomPayload", isDirectory: true)
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = .infinity
        cfg.timeoutIntervalForRequest = .infinity
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        manifest = Self.loadBundledV1Manifest()
        manifestV2 = try? PayloadManifestV2.bundled()
        if let m = manifestV2 {
            let saved = defaults.string(forKey: Self.variantDefaultsKey)
            variantKey = (saved.flatMap { m.variants[$0] != nil ? $0 : nil }) ?? m.defaultVariant
            base = PayloadBaseURL.resolve(manifestBase: m.urlBase,
                                          documents: Self.documentsURL,
                                          devDefault: Self.devLANBase)
        }
        DiagnosticsShim.sink = { Diagnostics.log($0) }
    }

    // MARK: configuration

    static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Selected attention variant (`sdpa` / `split_einsum`).
    var variant: String {
        get { variantKey }
        set {
            guard let m = manifestV2, m.variants[newValue] != nil else { return }
            variantKey = newValue
            defaults.set(newValue, forKey: Self.variantDefaultsKey)
            refreshTotals()
        }
    }

    var variants: [String] { manifestV2?.variants.keys.sorted() ?? [] }

    /// Base URL actually in use (override already applied).
    var baseURL: String { base }

    var overrideSource: String? {
        guard let docs = Self.documentsURL else { return nil }
        return PayloadBaseURL.override(in: docs)
    }

    private static func loadBundledV1Manifest() -> DeviceManifest? {
        guard let u = Bundle.main.url(forResource: "device_manifest", withExtension: "json"),
              let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(DeviceManifest.self, from: d)
    }

    private func refreshTotals() {
        guard let m = manifestV2 else { return }
        totalBytes = (try? m.bytes(forVariant: variantKey)) ?? 0
    }

    /// Entries needed for the selected variant, in manifest order.
    var entries: [PayloadManifestV2.FileEntry] {
        guard let m = manifestV2 else { return [] }
        return (try? m.entries(forVariant: variantKey)) ?? []
    }

    // MARK: state

    var state: PayloadState {
        guard let m = manifestV2 else {
            return .failed("device_manifest_v2.json missing from CraftRoomCore")
        }
        if !isReady {
            let total = (try? m.bytes(forVariant: variantKey)) ?? m.totalBytes
            return .missing(totalMB: total / 1_048_576)
        }
        return .ready
    }

    /// Every file of the selected variant present at exactly its declared size.
    /// (The sha256 is verified once, right after each download.)
    var isReady: Bool {
        guard manifestV2 != nil else { return false }
        for f in entries where !Self.fileComplete(f, in: root) { return false }
        return !entries.isEmpty
    }

    private static func fileComplete(_ f: PayloadManifestV2.FileEntry, in root: URL) -> Bool {
        let p = root.appendingPathComponent(f.path)
        guard let v = try? p.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(v) == f.size else { return false }
        return true
    }

    /// What `MLModel` needs for one payload model name.
    enum ModelSource {
        /// a downloaded, already-compiled `.mlmodelc` (the served form today)
        case compiled(URL)
        /// a downloaded `.mlpackage` source: compile on device first (plan B)
        case package(URL)
    }

    /// The loader's entry point: the installed directory for a model, in the
    /// shipping form the manifest declares for it (`form`, default `mlmodelc`).
    func modelSource(named: String) -> ModelSource? {
        guard let dir = modelDir(named: named) else { return nil }
        let form = manifestV2?.form(forModelNamed: named) ?? .mlmodelc
        return form.needsDeviceCompile ? .package(dir) : .compiled(dir)
    }

    /// Weight bytes of the **selected variant** only — the honest number for a
    /// load line, where `Diagnostics.bundledWeightBytes()` also counts stale
    /// `weight.bin` files of an older payload still sitting in the store.
    var variantWeightBytes: Int64 {
        entries.filter { $0.path.hasSuffix("weight.bin") }.reduce(0) { $0 + $1.size }
    }

    /// The downloaded model directory for the loader, nil until every file of
    /// that model is complete. Accepts the manifest model name with or without
    /// its extension; the extension that is looked for follows the manifest's
    /// `form` (`.mlpackage` when a model is served as a source package).
    func modelDir(named: String) -> URL? {
        if let m = manifestV2 {
            let stem = PayloadManifestV2.modelStem(named)
            let ext = m.form(forModelNamed: named).needsDeviceCompile
                ? ".mlpackage" : ".mlmodelc"
            let wanted = stem + ext
            let modelDirName: String
            if m.models.contains(wanted) || entries.contains(where: { $0.path.hasPrefix(wanted + "/") }) {
                modelDirName = wanted
            } else if let first = entries.first(where: { $0.path.hasPrefix(stem) }) {
                let head = first.path.split(separator: "/").first.map(String.init) ?? wanted
                modelDirName = head
            } else {
                return nil
            }
            let files = entries.filter { $0.path.hasPrefix(modelDirName + "/") }
            guard !files.isEmpty,
                  files.allSatisfy({ Self.fileComplete($0, in: root) }) else { return nil }
            return root.appendingPathComponent(modelDirName)
        }
        // legacy v1 path (device-v1 payload of an older bundle)
        guard let manifest else { return nil }
        let files = manifest.files.filter { $0.path.hasPrefix(named + ".mlmodelc/") }
        guard !files.isEmpty else { return nil }
        for f in files {
            let p = root.appendingPathComponent(f.path)
            guard let v = try? p.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(v) == f.size else { return nil }
        }
        return root.appendingPathComponent(named + ".mlmodelc")
    }

    /// Absolute URL of a payload-relative path (embeds, scheduler bins).
    func resourceURL(_ relativePath: String) -> URL? {
        let url = root.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: download

    /// Downloads every missing file of the selected variant, sequentially.
    /// Re-entrant: complete files are skipped, partial ones resume.
    @MainActor
    func downloadAll() async throws {
        guard let m = manifestV2 else {
            throw PipError.badPayload("device_manifest_v2.json missing from CraftRoomCore")
        }
        if base.isEmpty { base = PayloadBaseURL.resolve(manifestBase: m.urlBase,
                                                        documents: Self.documentsURL,
                                                        devDefault: Self.devLANBase) }
        refreshTotals()
        let pending = entries.filter { !Self.fileComplete($0, in: root) }
        settledBytes = totalBytes - pending.reduce(0) { $0 + $1.size }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        Diagnostics.log("payload: \(m.version) variant \(variantKey) base \(base) "
                        + "· \(pending.count) file(s), "
                        + "\(totalBytes / 1_048_576) MB total")
        for f in pending {
            guard let url = m.url(for: f, base: base) else {
                throw PipError.badPayload("bad url for \(f.path) against \(base)")
            }
            let dest = root.appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            let partial = dest.appendingPathExtension("part")
            try await download(f, from: url, to: partial)
            try await Task.detached(priority: .userInitiated) {
                try Self.verify(f, at: partial)
            }.value
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: partial, to: dest)
            settledBytes += f.size
            liveBytes = 0
            Diagnostics.log("payload: \(f.path) ok (\(f.size / 1_048_576) MB)")
        }
    }

    func cancel() {
        pendingTask?.cancel()
    }

    /// UI polls this while downloading (the session delegate runs off-main).
    func snapshot() -> (done: Int64, total: Int64) {
        (min(settledBytes + liveBytes, max(totalBytes, 1)), totalBytes)
    }

    // MARK: resumable file transfer

    private func download(_ f: PayloadManifestV2.FileEntry, from url: URL,
                          to partial: URL) async throws {
        let fm = FileManager.default
        var offset: Int64 = 0
        if let size = try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) > 0, Int64(size) < f.size {
            offset = Int64(size)
            Diagnostics.log("payload: resuming \(f.path) at \(offset) B")
        } else {
            try? fm.removeItem(at: partial)
            fm.createFile(atPath: partial.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: partial) else {
            throw PipError.badPayload("cannot open \(partial.path)")
        }
        _ = try? handle.seekToEnd()
        pendingHandle = handle
        pendingExpectation = (f.path, url)
        liveBytes = offset

        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingContinuation = cont
            let task = session.dataTask(with: request)
            pendingTask = task
            task.resume()
        }
    }

    private func finish(error: Error?) {
        try? pendingHandle?.close()
        pendingHandle = nil
        let cont = pendingContinuation
        pendingContinuation = nil
        pendingTask = nil
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // 200 means the server ignored our Range header → restart the file.
        if let http = response as? HTTPURLResponse, http.statusCode == 200,
           liveBytes > 0, let handle = pendingHandle, let expect = pendingExpectation {
            // 200 means the Range header was ignored (python's http.server) —
            // truncate so the bytes are not appended twice.
            try? handle.truncate(atOffset: 0)
            _ = try? handle.seek(toOffset: 0)
            liveBytes = 0
            Diagnostics.log("payload: \(expect.path) server sent 200, restarting")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if pendingHandle == nil {
            // arrived after a cancel; drop it
            pendingTask?.cancel()
            return
        }
        try? pendingHandle?.write(contentsOf: data)
        liveBytes += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }

    private static func verify(_ f: PayloadManifestV2.FileEntry, at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) == f.size else {
            throw PipError.badPayload("\(f.path): size \(size), expected \(f.size)")
        }
        var hasher = SHA256()
        let fh = try FileHandle(forReadingFrom: url)
        while let chunk = try fh.read(upToCount: 1 << 22), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        try fh.close()
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == f.sha256 else {
            throw PipError.badPayload("\(f.path): sha256 mismatch (\(hex.prefix(12))…)")
        }
    }

}
