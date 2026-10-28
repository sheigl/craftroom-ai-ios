import Foundation
import CryptoKit
import UIKit

/// One downloadable file of the device payload (see
/// scripts/publish_device_payload.py; the manifest is bundled as
/// Resources/device/device_manifest.json).
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

/// The models are compiled .mlmodelc directories downloaded on first launch
/// into Application Support/CraftRoomPayload/ (ITMS-90558: the int8 DiT alone
/// puts the app bundle over Apple's 4 GB thinned-bundle limit, so the weights
/// can no longer ride inside the ipa). The harness reads them from here;
/// Inference/Diagnostics fall back to the bundle for the old in-bundle build.
final class PayloadStore: NSObject, URLSessionDownloadDelegate {
    static let shared = PayloadStore()

    let root: URL
    private(set) var manifest: DeviceManifest?

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var liveBytes: Int64 = 0      // bytes of the in-flight file
    private var settledBytes: Int64 = 0   // files finished in this run
    private let queue = OperationQueue()

    private override init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("CraftRoomPayload", isDirectory: true)
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = .infinity
        cfg.timeoutIntervalForRequest = .infinity
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        manifest = Self.loadBundledManifest()
    }

    private static func loadBundledManifest() -> DeviceManifest? {
        guard let u = Bundle.main.url(forResource: "device_manifest",
                                      withExtension: "json"),
              let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(DeviceManifest.self, from: d)
    }

    var state: PayloadState {
        guard let manifest else {
            return .failed("device_manifest.json missing from the app bundle")
        }
        if !isReady {
            return .missing(totalMB: manifest.totalBytes / 1_048_576)
        }
        return .ready
    }

    /// All manifest files present at exactly their declared size. Size-only
    /// check here; the sha256 is verified once per file right after download.
    var isReady: Bool {
        guard let manifest else { return false }
        let fm = FileManager.default
        for f in manifest.files {
            let p = root.appendingPathComponent(f.path)
            guard let v = try? p.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(v) == f.size else { return false }
        }
        return true
    }

    /// The downloaded model dir for loadModel(named:), nil until complete.
    func modelDir(named: String) -> URL? {
        guard let manifest else { return nil }
        let dir = root.appendingPathComponent(named + ".mlmodelc")
        let files = manifest.files.filter { $0.path.hasPrefix(named + ".mlmodelc/") }
        guard !files.isEmpty else { return nil }
        for f in files {
            let p = root.appendingPathComponent(f.path)
            guard let v = try? p.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(v) == f.size else { return nil }
        }
        return dir
    }

    /// Download every missing file, sequentially. Safe to re-tap after a
    /// failure: completed files are skipped by size, so this resumes per file.
    @MainActor
    func downloadAll() async throws {
        guard let manifest else {
            throw PipError.badPayload("device_manifest.json missing from the app bundle")
        }
        let fm = FileManager.default
        let pending = manifest.files.filter { f in
            let p = root.appendingPathComponent(f.path)
            guard let v = try? p.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return true }
            return Int64(v) != f.size
        }
        settledBytes = manifest.totalBytes - pending.reduce(0) { $0 + $1.size }
        liveBytes = 0
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        for f in pending {
            let tmp = try await download(f)
            // sha256 over up to 3.9 GB must not run on the main actor
            try await Task.detached(priority: .userInitiated) { try self.verify(f, at: tmp) }.value
            let dest = root.appendingPathComponent(f.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            settledBytes += f.size
            liveBytes = 0
            Diagnostics.log("payload: \(f.path) ok (\(f.size / 1_048_576) MB)")
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// UI polls this while downloading (the delegate runs off-main).
    func snapshot() -> (done: Int64, total: Int64) {
        (settledBytes + liveBytes, manifest?.totalBytes ?? 0)
    }

    // MARK: download plumbing

    private func download(_ file: DeviceFile) async throws -> URL {
        guard let url = URL(string: file.url) else {
            throw PipError.badPayload("bad url for \(file.path)")
        }
        liveBytes = 0
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let t = session.downloadTask(with: url)
            task = t
            t.resume()
        }
    }

    private func verify(_ file: DeviceFile, at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) == file.size else {
            throw PipError.badPayload("\(file.path): size \(size), expected \(file.size)")
        }
        var hasher = SHA256()
        let fh = try FileHandle(forReadingFrom: url)
        while let chunk = try fh.read(upToCount: 1 << 22), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        try fh.close()
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == file.sha256 else {
            throw PipError.badPayload("\(file.path): sha256 mismatch")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        liveBytes = totalBytesWritten
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        liveBytes = fileOffset
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // the temp file is deleted when this returns — move it somewhere ours
        let keep = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".part")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            continuation?.resume(returning: keep)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
