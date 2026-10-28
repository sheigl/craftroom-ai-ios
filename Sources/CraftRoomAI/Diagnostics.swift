import Foundation
import UIKit
import Darwin

/// Device facts + a crash-surviving breadcrumb log.
///
/// Why this exists: on the iPad the app has no console, the Mac has no crash
/// report, and a jetsam kill produces neither an exception nor a dialog — the
/// app simply disappears. The only post-mortem that works is a line written
/// just before the kill, in a file the host can read afterwards
/// (UIFileSharingEnabled in project.yml exposes Documents/ to Finder).
enum Diagnostics {
    static let logURL: URL = {
        let base = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("phaseA.log")
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var build: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    /// hw.machine, e.g. iPad13,4 — tells us the SoC class and therefore the RAM
    /// the OS is willing to give one app.
    static var machine: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// os_proc_available_memory() looked up at runtime: the symbol lives in
    /// libSystem (iOS 13+) but is not reliably exported to the Swift overlay,
    /// and a dlsym lookup can never turn into a build error.
    private static let availFn: (@convention(c) () -> UInt64)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "os_proc_available_memory") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> UInt64).self)
    }()

    /// Bytes this process may still allocate before jetsam. nil if unavailable.
    static func availableMemoryMB() -> Double? {
        guard let f = availFn else { return nil }
        return Double(f()) / 1_048_576.0
    }

    static func physicalMemoryMB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576.0
    }

    static func footprintMB() -> Double {
        Double(currentFootprint()) / 1_048_576.0
    }

    /// One dense line: model id, OS, RAM, headroom, current footprint.
    static func summary() -> String {
        let headroom = availableMemoryMB().map { String(format: "%.0f free", $0) } ?? "free n/a"
        return "\(machine) · iPadOS \(UIDevice.current.systemVersion) · "
            + String(format: "%.0f MB RAM · %@ · footprint %.0f MB",
                     physicalMemoryMB(), headroom, footprintMB())
    }

    static func reset(_ header: String) {
        let line = "=== \(Date()) \(build) \(header)\n" + summary() + "\n"
            + memoryVerdict() + "\n"
        if let d = line.data(using: .utf8) { try? d.write(to: logURL) }
    }

    /// Bytes of CoreML weights actually installed: the first-launch download
    /// in Application Support (since ITMS-90558 moved them out of the ipa),
    /// the in-bundle copy for the legacy build, or — before anything is
    /// downloaded — the sizes declared in the bundled device manifest, so the
    /// verdict line is honest from the very first launch.
    static func bundledWeightBytes() -> UInt64 {
        var total: UInt64 = 0
        let fm = FileManager.default
        for root in [PayloadStore.shared.root, Bundle.main.resourceURL].compactMap({ $0 }) {
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in walk where url.lastPathComponent == "weight.bin" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += UInt64(max(0, size))
            }
            if total > 0 { return total }  // one installed source is enough
        }
        if let m = PayloadStore.shared.manifest {
            return m.files.filter { $0.path.hasSuffix("weight.bin") }
                .reduce(0) { $0 + UInt64(max(0, $1.size)) }
        }
        return 0
    }

    /// The verdict line the Phase A gate actually needs: how much room the OS
    /// is willing to give this process next to the bytes we want to map.
    static func memoryVerdict() -> String {
        let weights = Double(bundledWeightBytes()) / 1_048_576.0
        let budget = availableMemoryMB()
        let total = physicalMemoryMB()
        guard let budget else {
            return String(format: "%.0f MB RAM · headroom n/a", total)
        }
        let fits = budget >= weights + 320
        return String(format: "%@ · %.0f MB RAM · app budget %.0f MB · weights %.0f MB"
            + " → %@",
            machine, total, budget, weights,
            fits ? "plausible" : "IMPOSSIBLE (would be a silent kill)")
    }

    /// Last lines of the log, for the on-screen panel: file sharing is not
    /// guaranteed to survive a mis-generated Info.plist, and a screenshot of
    /// the tail is the one evidence path that always works.
    static func tail(_ maxLines: Int = 60) -> String {
        guard let s = try? String(contentsOf: logURL, encoding: .utf8) else {
            return "(no log yet — tap Generate once)"
        }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Append one timestamped line. Never throws; called from the pipeline so
    /// it must not disturb timing more than a small file write.
    static func log(_ msg: String) {
        let line = "\(stamp.string(from: Date())) \(msg)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(d)
        } else if let h = try? FileHandle(forWritingAtPath: logURL.path) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(d)
        } else {
            try? d.write(to: logURL)
        }
    }
}
