import AppKit
import Combine
import Foundation

/// Owns the clipboard history: an in-memory ordered list (newest first),
/// payload blobs on disk, and the retention purge.
@MainActor
final class ClipStore: ObservableObject {
    static let shared = ClipStore()

    @Published private(set) var items: [ClipItem] = []

    private let root: URL
    private let blobsDir: URL
    private let thumbsDir: URL
    private let indexURL: URL
    private var thumbCache: [UUID: NSImage] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Clipnotch", isDirectory: true)
        blobsDir = root.appendingPathComponent("blobs", isDirectory: true)
        thumbsDir = root.appendingPathComponent("thumbs", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")

        for dir in [root, blobsDir, thumbsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ClipItem].self, from: data)) ?? []
        purge()
        removeOrphanFiles()
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Insert

    /// Returns false when the capture was a duplicate of the newest entry.
    @discardableResult
    func insert(
        kind: ClipKind,
        payload: Data,
        textPreview: String?,
        pixelSize: CGSize?,
        thumbnail: Data?,
        sourceBundleID: String?
    ) -> Bool {
        let digest = ImageUtil.digest(payload)
        if items.first?.digest == digest { return false }

        let id = UUID()
        let blobName = id.uuidString + blobExtension(for: kind)
        do {
            try payload.write(to: blobsDir.appendingPathComponent(blobName), options: .atomic)
        } catch {
            Log.clipboard.error("blob write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        var thumbName: String?
        if let thumbnail {
            let name = id.uuidString + ".png"
            if (try? thumbnail.write(to: thumbsDir.appendingPathComponent(name), options: .atomic)) != nil {
                thumbName = name
            }
        }

        let item = ClipItem(
            id: id,
            kind: kind,
            createdAt: Date(),
            sourceBundleID: sourceBundleID,
            digest: digest,
            byteCount: payload.count,
            textPreview: textPreview,
            pixelWidth: pixelSize.map { Int($0.width) },
            pixelHeight: pixelSize.map { Int($0.height) },
            blobFile: blobName,
            thumbFile: thumbName
        )

        items.insert(item, at: 0)
        purge()
        saveIndex()
        return true
    }

    private func blobExtension(for kind: ClipKind) -> String {
        switch kind {
        case .image: return ".png"
        case .richText: return ".rtf"
        case .text, .files: return ".txt"
        }
    }

    // MARK: - Read

    func payload(for item: ClipItem) -> Data? {
        try? Data(contentsOf: blobsDir.appendingPathComponent(item.blobFile))
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        if let cached = thumbCache[item.id] { return cached }
        guard let name = item.thumbFile,
              let image = NSImage(contentsOf: thumbsDir.appendingPathComponent(name))
        else { return nil }
        thumbCache[item.id] = image
        return image
    }

    /// Full-resolution image, loaded on demand for the preview overlay.
    func fullImage(for item: ClipItem) -> NSImage? {
        guard item.kind == .image, let data = payload(for: item) else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Delete

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        removeFiles(for: item)
        thumbCache.removeValue(forKey: item.id)
        saveIndex()
    }

    func deleteAll() {
        for item in items { removeFiles(for: item) }
        items.removeAll()
        thumbCache.removeAll()
        saveIndex()
    }

    private func removeFiles(for item: ClipItem) {
        try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(item.blobFile))
        if let thumb = item.thumbFile {
            try? FileManager.default.removeItem(at: thumbsDir.appendingPathComponent(thumb))
        }
    }

    // MARK: - Retention

    /// Drops entries past the count cap or older than the age cap, deleting their
    /// files. Called on launch and after every insert.
    func purge() {
        let settings = Settings.shared
        var doomedIDs = Set<UUID>()

        if settings.retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(settings.retentionDays) * 86_400)
            doomedIDs.formUnion(items.filter { $0.createdAt < cutoff }.map(\.id))
        }
        if settings.retentionItems > 0, items.count > settings.retentionItems {
            doomedIDs.formUnion(items.dropFirst(settings.retentionItems).map(\.id))
        }

        guard !doomedIDs.isEmpty else { return }

        for item in items where doomedIDs.contains(item.id) {
            removeFiles(for: item)
            thumbCache.removeValue(forKey: item.id)
        }
        items.removeAll { doomedIDs.contains($0.id) }
        Log.clipboard.info("purged \(doomedIDs.count, privacy: .public) clips")
    }

    /// Deletes blobs and thumbs with no index entry, e.g. after a crash.
    private func removeOrphanFiles() {
        let known = Set(items.map(\.blobFile))
        let knownThumbs = Set(items.compactMap(\.thumbFile))
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: blobsDir.path)) ?? [] where !known.contains(file) {
            try? fm.removeItem(at: blobsDir.appendingPathComponent(file))
        }
        for file in (try? fm.contentsOfDirectory(atPath: thumbsDir.path)) ?? [] where !knownThumbs.contains(file) {
            try? fm.removeItem(at: thumbsDir.appendingPathComponent(file))
        }
    }

    var diskUsage: Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for dir in [blobsDir, thumbsDir] {
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let path = dir.appendingPathComponent(file).path
                if let size = try? fm.attributesOfItem(atPath: path)[.size] as? Int64 {
                    total += size
                }
            }
        }
        return total
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path)
    }
}
