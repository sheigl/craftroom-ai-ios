import CoreML
import Foundation
import CraftRoomCore

/// Plan B: compile a shipped `.mlpackage` **on the device** (build 10, off by
/// default).
///
/// What decides this: the self-test. If `SELFTEST FAILED` says the 198 MB
/// macOS-compiled `VAEDecoder_sdxl_fp32` cannot even load, the compiled form
/// itself is suspect (hypothesis B) and the answer is to serve the `.mlpackage`
/// sources instead — they already sit on the payload host (`packages/*.mlpackage`,
/// `device_v2/vae/*.mlpackage`) — and let iOS compile them with
/// `MLModel.compileModel(at:)`.
///
/// The switch is a manifest entry, not a code change: `"form": "mlpackage"` on
/// the variant (or in `modelForms`) makes the app download that tree and compile
/// it once into `Caches/DeviceCompiled/`. The served manifest is unchanged here:
/// it stays `mlmodelc`, the form that demonstrably loads on iOS (the v0.4 klein
/// payload ran from macOS-compiled `.mlmodelc` trees).
///
/// All decisions (which form, which cache directory, cache invalidation) are
/// pure functions in `CraftRoomCore` (`ModelForm`, `DeviceCompileCache`) and
/// unit-tested there; this is the thin Core ML wrapper.
enum DeviceCompiler {
    /// Compiled models live in Caches, keyed by content so a re-baked model is
    /// never served from a stale compile.
    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceCompiled", isDirectory: true)
    }

    enum CompileError: Error, CustomStringConvertible {
        case noSource(String), failed(String)
        var description: String {
            switch self {
            case .noSource(let m): return "no .mlpackage source installed for \(m)"
            case .failed(let m):   return "on-device compile failed: \(m)"
            }
        }
    }

    /// Path of the cached `.mlmodelc` for a model, compiling it if needed.
    /// Logs `compile on device … start` and `compile on device … in N s`, so a
    /// kill *during* compilation is distinguishable from a kill during load.
    static func compiledURL(forModelNamed name: String, sourcePackage: URL) throws -> URL {
        let key = contentKey(forPackageNamed: sourcePackage.lastPathComponent)
        let target = cacheRoot.appendingPathComponent(
            DeviceCompileCache.cacheDirectoryName(model: name, contentKey: key))
        let marker = target.appendingPathComponent("metadata.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            LadderLog.instrument("compile cache hit \(target.lastPathComponent)")
            return target
        }
        guard FileManager.default.fileExists(atPath: sourcePackage.path) else {
            throw CompileError.noSource(name)
        }
        try FileManager.default.createDirectory(at: cacheRoot,
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)

        let t0 = Date()
        let started = Diagnostics.footprintMB()
        LadderLog.instrument(String(format:
            "compile on device %@ start · source %@ · disk free %.0f MB · footprint %.0f MB",
            name, sourcePackage.lastPathComponent, freeCacheMB(), started))
        do {
            let compiled = try MLModel.compileModel(at: sourcePackage)
            try publish(compiled, to: target)
            LadderLog.instrument(String(format:
                "compile on device %@ in %.1f s → Caches/DeviceCompiled/%@"
                + " · footprint %.0f → %.0f MB",
                name, Date().timeIntervalSince(t0), target.lastPathComponent,
                started, Diagnostics.footprintMB()))
            return target
        } catch {
            LadderLog.instrument("compile on device \(name) FAILED after "
                + String(format: "%.1f s", Date().timeIntervalSince(t0))
                + " · \(error.localizedDescription)")
            throw CompileError.failed("\(name): \(error.localizedDescription)")
        }
    }

    /// The compiled bundle must end up at `target`: move it, copy if the move
    /// crosses something that will not allow it.
    private static func publish(_ compiled: URL, to target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        do {
            try FileManager.default.moveItem(at: compiled, to: target)
        } catch {
            try FileManager.default.copyItem(at: compiled, to: target)
            try? FileManager.default.removeItem(at: compiled)
        }
    }

    private static func freeCacheMB() -> Double {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: cacheRoot.path)
        let bytes = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return Double(bytes) / 1_048_576.0
    }

    /// Manifest-derived content key of one model directory. A model that is not
    /// in the manifest gets a stable placeholder key instead of a crash: the
    /// cache name only has to be stable and invalidatable.
    static func contentKey(forPackageNamed dirName: String) -> String {
        let entries = PayloadStore.shared.entries
        let covered = entries.contains { $0.path.hasPrefix(dirName + "/") }
        guard covered else { return "nomanifest-\(dirName.count)" }
        return DeviceCompileCache.contentKey(for: entries, modelDirectory: dirName)
    }
}
