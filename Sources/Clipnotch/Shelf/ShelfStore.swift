import AppKit
import Combine
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }
}

/// Files parked on the shelf so they can be carried to another display without
/// holding the mouse button down the whole way. One shelf for all displays:
/// that is the point of it.
///
/// Items are references, not copies. Dragging one out lets the destination
/// decide whether to move or copy, and a shelved file that disappears from
/// disk drops off the shelf.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<ShelfItem.ID> = []

    private init() {}

    func add(_ urls: [URL]) {
        let known = Set(items.map { $0.url.standardizedFileURL })
        let fresh = urls
            .map(\.standardizedFileURL)
            .reduce(into: [URL]()) { result, url in
                if !known.contains(url), !result.contains(url) { result.append(url) }
            }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh.map { ShelfItem(url: $0) })
    }

    func remove(_ ids: Set<ShelfItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func removeAll() {
        items.removeAll()
        selection.removeAll()
    }

    func toggleSelection(_ item: ShelfItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    /// What a drag starting on `item` carries: the whole selection when the
    /// item is part of it, otherwise just the item.
    func dragPayload(startingAt item: ShelfItem) -> [ShelfItem] {
        guard selection.contains(item.id) else { return [item] }
        return items.filter { selection.contains($0.id) }
    }

    /// Drops entries whose file was moved or deleted behind the shelf's back.
    func pruneMissing() {
        let missing = Set(items.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.id))
        if !missing.isEmpty { remove(missing) }
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Drop

    /// Loads the file URLs out of a drop. Providers call back off the main
    /// thread, so the result is delivered back on it in one batch.
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                // Some sources hand over `/.file/id=` reference URLs; the
                // shelf needs a real path for icons, names and dedup.
                if let url, url.isFileURL, let path = (url as NSURL).filePathURL {
                    lock.lock()
                    urls.append(path)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(urls) }
        }
    }
}

/// Source of drags out of the shelf. A long-lived object rather than the tile
/// view, because the panel may close — and tear the view down — mid-drag.
@MainActor
final class ShelfDragSource: NSObject, NSDraggingSource {
    static let shared = ShelfDragSource()

    /// True while a drag that started on the shelf is in flight, so the shelf
    /// does not accept its own items back.
    private(set) var isDragging = false
    private var dragged: Set<ShelfItem.ID> = []

    func begin(items: [ShelfItem], event: NSEvent, from view: NSView) {
        guard !items.isEmpty else { return }

        let iconSide: CGFloat = 48
        let origin = view.convert(event.locationInWindow, from: nil)
        let draggingItems = items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            // Fanned out slightly, so several files read as a stack.
            let offset = CGFloat(min(index, 4)) * 5
            let frame = NSRect(
                x: origin.x - iconSide / 2 + offset,
                y: origin.y - iconSide / 2 - offset,
                width: iconSide,
                height: iconSide
            )
            draggingItem.setDraggingFrame(frame, contents: ShelfStore.icon(for: item.url))
            return draggingItem
        }

        dragged = Set(items.map(\.id))
        isDragging = true
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Move is what makes it a shelf rather than a copy machine; Finder
        // still copies across volumes on its own.
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        MainActor.assumeIsolated {
            // Delivered somewhere: it has left the shelf. A cancelled drag
            // animates back and stays.
            if !operation.isEmpty {
                ShelfStore.shared.remove(dragged)
            }
            dragged = []
            isDragging = false
            NotchManager.shared.fileDragEnded()
        }
    }
}
