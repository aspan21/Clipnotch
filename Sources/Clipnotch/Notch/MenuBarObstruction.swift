import AppKit
import ApplicationServices
import Combine

/// Where the frontmost app's menu titles sit, so the closed notch can keep its
/// flanks off them.
///
/// macOS lays menus out around the hardware cutout, never under it — but it
/// knows nothing about the flanks we draw beside it. An app with a long menu
/// runs its titles right up to the cutout, or wraps them past it, and a flank
/// drawn there covers them. Read through Accessibility, which the paste queue
/// already needs; without the grant this reports nothing and the flanks show
/// as before.
@MainActor
final class MenuBarObstruction: ObservableObject {
    static let shared = MenuBarObstruction()

    /// Menu title frames, in Cocoa global coordinates.
    @Published private(set) var titleFrames: [CGRect] = []

    /// Menus can change without an app switch (a different window, a
    /// different document type), and there is no notification for that.
    private static let pollInterval: TimeInterval = 3
    /// A menu being read over IPC must never stall the app.
    private nonisolated static let messagingTimeout: Float = 0.25

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "clipnotch.menubar", qos: .utility)
    private var generation = 0

    private init() {}

    func start() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    // Some apps build their menus a beat after activating.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refresh() }
                }
            }
            .store(in: &cancellables)

        ScreenActivity.shared.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { active ? self?.startTimer() : self?.stopTimer() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        stopTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// True when any menu title reaches into `rect` (Cocoa global coordinates).
    func obstructs(_ rect: CGRect) -> Bool {
        titleFrames.contains { $0.intersects(rect) }
    }

    func refresh() {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let primaryHeight = NSScreen.screens.first?.frame.height
        else {
            if !titleFrames.isEmpty { titleFrames = [] }
            return
        }

        generation += 1
        let token = generation
        let pid = app.processIdentifier

        queue.async { [weak self] in
            let frames = Self.readMenuTitles(pid: pid, primaryHeight: primaryHeight)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation, frames != self.titleFrames else { return }
                    self.titleFrames = frames
                }
            }
        }
    }

    private nonisolated static func readMenuTitles(pid: pid_t, primaryHeight: CGFloat) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBar, CFGetTypeID(menuBar) == AXUIElementGetTypeID()
        else { return [] }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement]
        else { return [] }

        return items.compactMap { item in
            guard let origin = point(of: item), let size = size(of: item),
                  size.width > 0, size.height > 0
            else { return nil }
            // Accessibility is top-left based on the primary display; Cocoa is
            // bottom-left. Horizontal positions agree.
            return CGRect(x: origin.x, y: primaryHeight - origin.y - size.height,
                          width: size.width, height: size.height)
        }
    }

    private nonisolated static func point(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private nonisolated static func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
