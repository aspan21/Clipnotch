import AppKit
import Foundation

/// Writes a stored clip back onto the system pasteboard in the same shape it
/// was captured, so the receiving app sees a normal copy.
enum PasteboardWriter {
    /// Snapshot of the pasteboard, detached from the live board so it survives writes.
    struct Snapshot {
        let items: [NSPasteboardItem]
    }

    static func snapshotCurrent() -> Snapshot {
        let copies = (NSPasteboard.general.pasteboardItems ?? []).map { source -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return Snapshot(items: copies)
    }

    /// Returns the resulting changeCount so the monitor can ignore this write.
    @discardableResult
    static func restore(_ snapshot: Snapshot) -> Int {
        let board = NSPasteboard.general
        board.clearContents()
        if !snapshot.items.isEmpty {
            board.writeObjects(snapshot.items)
        }
        return board.changeCount
    }

    @discardableResult
    static func write(_ item: ClipItem, payload: Data) -> Int {
        let board = NSPasteboard.general
        board.clearContents()

        switch item.kind {
        case .image:
            let entry = NSPasteboardItem()
            entry.setData(payload, forType: .png)
            if let image = NSImage(data: payload), let tiff = image.tiffRepresentation {
                entry.setData(tiff, forType: .tiff)
            }
            board.writeObjects([entry])

        case .text:
            board.setString(String(data: payload, encoding: .utf8) ?? "", forType: .string)

        case .richText:
            let entry = NSPasteboardItem()
            entry.setData(payload, forType: .rtf)
            if let plain = item.textPreview {
                entry.setString(plain, forType: .string)
            }
            board.writeObjects([entry])

        case .files:
            let paths = (item.textPreview ?? "").split(separator: "\n").map(String.init)
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            if urls.isEmpty {
                board.setString(item.textPreview ?? "", forType: .string)
            } else {
                board.writeObjects(urls)
            }
        }

        return board.changeCount
    }
}
