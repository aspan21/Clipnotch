import AppKit
import Combine
import SwiftUI

/// One panel per display, kept in sync with the display arrangement. Each panel
/// owns its own `NotchController`, so a notch on an external monitor opens and
/// closes independently of the built-in one.
@MainActor
final class NotchManager {
    static let shared = NotchManager()

    private struct Panel {
        let controller: NotchController
        let window: NotchWindow
    }

    private var panels: [CGDirectDisplayID: Panel] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    /// Drag pasteboard generation at the last mouse-down. A different one
    /// during the drag means a real drag session started since.
    private var dragChangeCount = 0
    private var isFileDragging = false

    private init() {}

    func start() {
        rebuild()
        startPointerTracking()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        stopPointerTracking()
        for panel in panels.values { teardown(panel) }
        panels.removeAll()
    }

    /// Controller the keyboard shortcut and the menu bar item act on: the panel
    /// on the display under the pointer.
    var focused: NotchController? {
        if let screen = NotchGeometry.focusedScreen,
           let id = NotchGeometry.displayID(for: screen),
           let panel = panels[id] {
            return panel.controller
        }
        return panels.values.first?.controller
    }

    // MARK: - Peek on notch-less displays

    /// A display without a cutout has no dead strip to hide in, so its closed
    /// panel stays collapsed until the pointer reaches the top-centre band.
    /// Tracked through event monitors rather than an invisible hover view: a
    /// view large enough to catch the pointer would also swallow clicks meant
    /// for the window underneath.
    private func startPointerTracking() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp,
        ]

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handlePointer(type) }
        })
        if let global { mouseMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handlePointer(type) }
            return event
        })
        if let local { mouseMonitors.append(local) }
    }

    private func stopPointerTracking() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
    }

    private func handlePointer(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            isFileDragging = false
        case .leftMouseDragged:
            updatePeek()
            updateFileDrag()
        case .leftMouseUp:
            if isFileDragging { fileDragEnded() }
        default:
            updatePeek()
            trackDragOpenedPanels()
        }
    }

    // MARK: - File drags

    /// Opens the shelf on whichever display's notch a file drag reaches.
    ///
    /// Read off the drag pasteboard and the pointer rather than drop callbacks:
    /// the closed strip is too small a target to rely on, and hover tracking is
    /// suspended for the whole drag.
    private func updateFileDrag() {
        if !isFileDragging {
            let board = NSPasteboard(name: .drag)
            guard board.changeCount != dragChangeCount,
                  board.types?.contains(.fileURL) == true
            else { return }
            isFileDragging = true
        }
        // Carrying files off the shelf is not a reason to open another one.
        guard !ShelfDragSource.shared.isDragging else {
            trackDragOpenedPanels()
            return
        }

        let mouse = NSEvent.mouseLocation
        for (id, panel) in panels {
            guard let screen = NotchGeometry.screen(for: id) else { continue }
            let controller = panel.controller
            if NotchGeometry.dragZone(on: screen, closedSize: controller.closedSize).contains(mouse) {
                controller.fileDragEntered()
            }
        }
        trackDragOpenedPanels()
    }

    /// A file drag finished, from another app or off the shelf. Hover tracking
    /// missed the whole thing, so any panel the pointer is no longer over closes.
    func fileDragEnded() {
        isFileDragging = false
        Task { @MainActor [weak self] in
            // Let the drop land before the panel starts folding away.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            for (id, panel) in self.panels {
                let controller = panel.controller
                guard controller.isOpen, controller.previewItem == nil,
                      let screen = NotchGeometry.screen(for: id)
                else { continue }
                let frame = NotchGeometry.panelFrame(on: screen, size: controller.currentSize)
                if !frame.contains(mouse) { controller.close() }
            }
        }
    }

    private func trackDragOpenedPanels() {
        let mouse = NSEvent.mouseLocation
        for (id, panel) in panels where panel.controller.openedForDrag {
            guard let screen = NotchGeometry.screen(for: id) else { continue }
            let controller = panel.controller
            let frame = NotchGeometry.panelFrame(on: screen, size: controller.currentSize)
                .insetBy(dx: -16, dy: -16)
            controller.dragPointerMoved(inside: frame.contains(mouse))
        }
    }

    private func updatePeek() {
        let mouse = NSEvent.mouseLocation

        for (id, panel) in panels {
            let controller = panel.controller
            guard !controller.hasPhysicalNotch else { continue }
            guard let screen = NotchGeometry.screen(for: id) else { continue }

            let inside = NotchGeometry.peekZone(on: screen, closedSize: controller.closedSize)
                .contains(mouse)
            guard controller.isPeeking != inside else { continue }
            controller.isPeeking = inside
        }
    }

    private func rebuild() {
        var live: Set<CGDirectDisplayID> = []

        for screen in NSScreen.screens {
            guard let id = NotchGeometry.displayID(for: screen) else { continue }
            live.insert(id)

            if let panel = panels[id] {
                panel.controller.refreshClosedSize()
                panel.window.setFrame(NotchGeometry.windowFrame(on: screen), display: true)
            } else {
                panels[id] = makePanel(for: screen, displayID: id)
            }
        }

        for (id, panel) in panels where !live.contains(id) {
            teardown(panel)
            panels[id] = nil
        }
    }

    private func makePanel(for screen: NSScreen, displayID: CGDirectDisplayID) -> Panel {
        let controller = NotchController(displayID: displayID)
        let window = NotchWindow(contentRect: NotchGeometry.windowFrame(on: screen))
        let hosting = NSHostingView(rootView: NotchRootView(controller: controller))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.orderFrontRegardless()

        // Joining a max-level private space is what keeps the panel visible over
        // fullscreen apps; without it macOS hides it on fullscreen spaces.
        NotchSpace.shared?.windows.insert(window)

        return Panel(controller: controller, window: window)
    }

    private func teardown(_ panel: Panel) {
        NotchSpace.shared?.windows.remove(panel.window)
        panel.window.orderOut(nil)
        panel.window.contentView = nil
    }
}
