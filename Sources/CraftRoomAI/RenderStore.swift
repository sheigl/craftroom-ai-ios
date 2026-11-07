import UIKit
import CraftRoomCore

/// One saved page in `Documents/renders/`, plus the source photo sidecar
/// (`<stem>.source.jpg`) that makes the before/after slider work.
///
/// Renders written before v0.6 (the ladder's `renders/*.png`) have no sidecar:
/// `sourceURL` is nil and the detail view hides the slider instead of showing a
/// broken comparison. Nothing is migrated or rewritten — old files stay exactly
/// as the grader found them.
struct RenderItem: Identifiable, Hashable {
    let pageURL: URL
    let sourceURL: URL?
    let createdAt: Date

    var id: String { pageURL.lastPathComponent }
    var name: String {
        pageURL.deletingPathExtension().lastPathComponent
    }
    var hasSource: Bool { sourceURL != nil }

    var pageImage: UIImage? { UIImage(contentsOfFile: pageURL.path) }
    var sourceImage: UIImage? {
        sourceURL.flatMap { UIImage(contentsOfFile: $0.path) }
    }
}

/// Save/list/delete pages in `Documents/renders/` (also reachable from Files
/// via `UIFileSharingEnabled`, which is how the owner pulls pages for grading).
enum RenderStore {
    static let folderName = "renders"
    static let sourceSuffix = ".source.jpg"

    static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Writes `<name>.png` and returns `renders/<name>.png` (the ladder's
    /// naming contract, kept so the grader still finds its files).
    @discardableResult
    static func savePNG(_ data: Data, name: String) -> String? {
        guard let dir = directory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.hasSuffix(".png") ? name : name + ".png")
        do {
            try data.write(to: url, options: .atomic)
            return "\(folderName)/\(url.lastPathComponent)"
        } catch {
            Diagnostics.log("ERROR saving render: \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves a product page and its source photo sidecar.
    static func save(page: PageResult, sourcePhoto: UIImage?) throws -> RenderItem {
        guard let dir = directory else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let engine = page.metadata.engine
        var stem = "page-\(stamp.string(from: Date()))-\(engine)"
        var pageURL = dir.appendingPathComponent(stem + ".png")
        // Same-second saves must not overwrite each other.
        var index = 2
        while FileManager.default.fileExists(atPath: pageURL.path) {
            stem = "page-\(stamp.string(from: Date()))-\(engine)-\(index)"
            pageURL = dir.appendingPathComponent(stem + ".png")
            index += 1
        }
        try page.png.write(to: pageURL, options: .atomic)

        var sourceURL: URL?
        if let sourcePhoto, let jpeg = sourcePhoto.jpegData(compressionQuality: 0.9) {
            let url = dir.appendingPathComponent(stem + sourceSuffix)
            if (try? jpeg.write(to: url, options: .atomic)) != nil {
                sourceURL = url
            } else {
                Diagnostics.log("warning: could not write the source sidecar for \(stem)")
            }
        }
        return RenderItem(pageURL: pageURL, sourceURL: sourceURL, createdAt: Date())
    }

    /// Every saved page, newest first. Old ladder renders included; their
    /// sidecar is simply absent.
    static func list() -> [RenderItem] {
        guard let dir = directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }
        let pages = urls.filter { $0.pathExtension.lowercased() == "png" }
        let items: [RenderItem] = pages.map { url in
            let sourceCandidate = url.deletingPathExtension()
                .appendingPathExtension("source.jpg")
            let exists = FileManager.default.fileExists(atPath: sourceCandidate.path)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            return RenderItem(pageURL: url,
                              sourceURL: exists ? sourceCandidate : nil,
                              createdAt: modified)
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ item: RenderItem) {
        try? FileManager.default.removeItem(at: item.pageURL)
        if let source = item.sourceURL {
            try? FileManager.default.removeItem(at: source)
        }
    }
}
