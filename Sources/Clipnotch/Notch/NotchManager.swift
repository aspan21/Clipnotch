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
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePeek() }
        })
        if let global { mouseMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePeek() }
            return event
        })
        if let local { mouseMonitors.append(local) }
    }

    private func stopPointerTracking() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
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
