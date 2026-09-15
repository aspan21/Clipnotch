import AppKit
import Foundation

enum ClipKind: String, Codable {
    case image
    case text
    case richText
    case files
}

/// One clipboard entry. The payload lives on disk; this is the index record.
struct ClipItem: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: ClipKind
    var createdAt: Date
    var sourceBundleID: String?
    /// SHA-256 of the payload, used to skip consecutive duplicates.
    var digest: String
    var byteCount: Int
    /// Plain-text preview for text/richText/files.
    var textPreview: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var blobFile: String
    var thumbFile: String?

    var pixelSize: CGSize? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return CGSize(width: w, height: h)
    }

    var sourceAppName: String? {
        guard let id = sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    var sourceAppIcon: NSImage? {
        guard let id = sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Short label shown under a card.
    var subtitle: String {
        switch kind {
        case .image:
            if let size = pixelSize {
                return "\(Int(size.width))x\(Int(size.height))"
            }
            return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        case .files:
            let count = (textPreview ?? "").split(separator: "\n").count
            return String(localized: "\(count) files")
        case .text, .richText:
            let chars = textPreview?.count ?? 0
            return String(localized: "\(chars) characters")
        }
    }
}
