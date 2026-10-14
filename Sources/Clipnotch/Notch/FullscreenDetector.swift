import AppKit
import Combine

/// Tracks which displays currently have a fullscreen app on them.
///
/// The panel joins a max-level private space (`NotchSpace`) so it stays visible
/// over fullscreen windows. That is what you want for the open panel and the
/// wrong thing for the closed strip, which would otherwise sit on top of a
/// fullscreen video. So on those displays the closed notch stays collapsed
/// until the pointer reaches the top, the way it does on a display without a
/// cutout.
///
/// Detection is public API only: a fullscreen window is a layer-0 window whose
/// bounds cover its whole display. No dependency, no private framework.
@MainActor
final class FullscreenDetector: ObservableObject {
    static let shared = FullscreenDetector()

    @Published private(set) var fullscreenDisplays: Set<CGDirectDisplayID> = []

    /// The space animation outlasts the notification, so sample after it settles.
    private static let settleDelay = Duration.milliseconds(350)
    /// A fullscreen window on a notched display stops below the cutout, so the
    /// height match cannot be exact.
    private static let heightSlack: CGFloat = 44

    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    private init() {}

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
        ] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            .store(in: &cancellables)

        scheduleRefresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        cancellables.removeAll()
        fullscreenDisplays = []
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        let displays = NSScreen.screens.compactMap(NotchGeometry.displayID(for:))
        guard !displays.isEmpty else { return }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        var covered: Set<CGDirectDisplayID> = []
        for window in windows {
            // Layer 0 is the normal document layer; the menu bar, the Dock and
            // our own panel all live above it.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }

            for display in displays where covers(frame, display: display) {
                covered.insert(display)
            }
        }

        if covered != fullscreenDisplays {
            fullscreenDisplays = covered
        }
    }

    private func covers(_ frame: CGRect, display: CGDirectDisplayID) -> Bool {
        // CGWindowList and CGDisplayBounds share the same flipped global space,
        // so the rects are directly comparable.
        let bounds = CGDisplayBounds(display)
        return abs(frame.minX - bounds.minX) <= 1
            && abs(frame.width - bounds.width) <= 1
            && frame.height >= bounds.height - Self.heightSlack
    }
}
