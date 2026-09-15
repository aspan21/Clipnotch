import AppKit
import Combine
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case nowPlaying
    case clipboard
    case shelf
    case pomodoro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return String(localized: "Now Playing")
        case .clipboard: return String(localized: "Clipboard")
        case .shelf: return String(localized: "Shelf")
        case .pomodoro: return String(localized: "Pomodoro")
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .clipboard: return "square.on.square.dashed"
        case .shelf: return "tray.full"
        case .pomodoro: return "timer"
        }
    }
}

/// What the closed notch shows beside the cutout, highest priority first.
enum ClosedActivity: Equatable {
    case none
    case pasteQueue
    case pomodoro
    case media
}

/// Owns open/closed state, gesture state and the sizing that one display's
/// SwiftUI tree reads. One instance per display; `NotchManager` creates them.
@MainActor
final class NotchController: ObservableObject {
    let displayID: CGDirectDisplayID

    @Published var isOpen = false
    @Published var tab: NotchTab = .nowPlaying
    @Published var closedSize: CGSize
    /// Full-resolution preview of a clip, shown as an overlay inside the panel.
    @Published var previewItem: ClipItem?
    /// Live travel of the pan pulling the panel open (positive) or pushing it
    /// shut (negative), in points.
    @Published var gestureTravel: CGFloat = 0
    @Published private(set) var isFullscreenCovered = false
    /// Pointer is in this display's top-centre band. Only consulted on displays
    /// without a physical cutout, where the closed strip stays hidden until then.
    @Published var isPeeking = false
    /// Whether the hardware already eats the strip we draw. False means the
    /// strip would cover real content.
    @Published private(set) var hasPhysicalNotch: Bool
    /// A file drag is hovering over the open panel.
    @Published var isShelfDropTargeted = false
    /// Opened because a file drag reached the notch. Hover tracking is
    /// suspended during a drag, so closing has to be driven by the pointer
    /// monitor instead of `onHover`.
    var openedForDrag = false

    /// Points of pull that commit to opening or closing.
    static let commitThreshold: CGFloat = 120
    /// Gap between the closed notch's live content and the outer edge.
    static let flankGutter: CGFloat = 10
    /// How much shorter the closed content is than the cutout it sits beside.
    static let closedContentInset: CGFloat = 12

    private var hoverCloseTask: Task<Void, Never>?
    private var dragCloseTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let screen = NotchGeometry.screen(for: displayID)
        closedSize = NotchGeometry.closedSize(for: screen)
        hasPhysicalNotch = NotchGeometry.hasPhysicalNotch(screen)
        observeFullscreen()
    }

    // MARK: - Sizing

    func refreshClosedSize() {
        let screen = NotchGeometry.screen(for: displayID)
        closedSize = NotchGeometry.closedSize(for: screen)
        hasPhysicalNotch = NotchGeometry.hasPhysicalNotch(screen)
    }

    /// Flank width while the pomodoro clock shows: the time needs more room
    /// than a square glyph.
    static let pomodoroFlankWidth: CGFloat = 48

    /// Closed strip hidden entirely: an external display has no cutout to hide
    /// it in, so it would sit on top of the window content underneath.
    var isConcealed: Bool {
        !hasPhysicalNotch && !isOpen && !isPeeking
    }

    /// Collapses to nothing while a fullscreen app owns this display.
    var effectiveClosedHeight: CGFloat {
        (isFullscreenCovered || isConcealed) ? 0 : closedSize.height
    }

    /// Side of the album art and the pips shown beside the cutout.
    var closedContentSize: CGFloat {
        max(0, effectiveClosedHeight - Self.closedContentInset)
    }

    /// Width added to each side of the cutout when the closed notch shows live
    /// content. Derived from that content, so the flanks and the frame can
    /// never disagree about how wide the strip is.
    var flankWidth: CGFloat {
        closedContentSize > 0 ? closedContentSize + Self.flankGutter : 0
    }

    /// Width each flank actually occupies: zero unless there is live content,
    /// so the flanks and the frame can never disagree by a few points.
    var activeFlankWidth: CGFloat {
        hasClosedContent ? flankWidth(for: closedActivity) : 0
    }

    private func flankWidth(for activity: ClosedActivity) -> CGFloat {
        activity == .pomodoro ? max(flankWidth, Self.pomodoroFlankWidth) : flankWidth
    }

    var hasClosedContent: Bool {
        guard !isFullscreenCovered, !isConcealed else { return false }
        let activity = closedActivity
        guard activity != .none else { return false }
        // Flanks that would cover the frontmost app's menu titles stay folded:
        // the menu is the thing the user came to the top of the screen for.
        return !menuTitlesBlockFlanks(width: flankWidth(for: activity))
    }

    /// Whether a flank of `width` on either side of the cutout would land on a
    /// menu title.
    private func menuTitlesBlockFlanks(width: CGFloat) -> Bool {
        guard let screen = NotchGeometry.screen(for: displayID) else { return false }
        // A title ending a hair short of the flank still looks crowded.
        let margin: CGFloat = 6
        let half = closedSize.width / 2
        let band = CGRect(x: 0, y: screen.frame.maxY - closedSize.height,
                          width: width + margin, height: closedSize.height)
        let left = band.offsetBy(dx: screen.frame.midX - half - width - margin, dy: 0)
        let right = band.offsetBy(dx: screen.frame.midX + half, dy: 0)
        let menus = MenuBarObstruction.shared
        return menus.obstructs(left) || menus.obstructs(right)
    }

    /// Like Dynamic Island, only something live earns the flanks: paused
    /// media folds back into a plain notch once `NowPlayingModel` stops
    /// calling it live.
    var closedActivity: ClosedActivity {
        if PasteQueue.shared.isActive { return .pasteQueue }
        if PomodoroTimer.shared.isLive { return .pomodoro }
        if NowPlayingModel.shared.isLive { return .media }
        return .none
    }

    /// Closed footprint, widened so live content sits beside the physical cutout
    /// instead of behind it where the hardware would hide it.
    var effectiveClosedSize: CGSize {
        CGSize(
            width: closedSize.width + activeFlankWidth * 2,
            height: effectiveClosedHeight
        )
    }

    /// Header row height, shared by the panel header and the preview's.
    var headerHeight: CGFloat {
        max(28, closedSize.height)
    }

    var currentSize: CGSize {
        guard isOpen else { return effectiveClosedSize }
        guard let item = previewItem else { return NotchGeometry.openSize }
        let pixels = item.pixelSize ?? CGSize(width: 4, height: 3)
        let aspect = pixels.height > 0 ? pixels.width / pixels.height : 4.0 / 3.0
        return NotchGeometry.previewSize(imageAspect: aspect, headerHeight: headerHeight)
    }

    var cornerRadii: (top: CGFloat, bottom: CGFloat) {
        isOpen ? NotchGeometry.cornerRadii.open : NotchGeometry.cornerRadii.closed
    }

    /// The spring for the state being animated *towards*. Opening follows a
    /// pull so it may overshoot; closing is critically damped so the panel
    /// never bounces back at the user.
    var resizeAnimation: Animation {
        isOpen ? Theme.notchOpen : Theme.notchClose
    }

    /// -1…1 pull from the live gesture, for the stretch that hints where the
    /// gesture is heading.
    var gesturePull: CGFloat {
        max(-1, min(1, gestureTravel / Self.commitThreshold))
    }

    // MARK: - Open / close

    func open(tab: NotchTab? = nil) {
        hoverCloseTask?.cancel()
        if let tab { self.tab = tab }
        gestureTravel = 0
        guard !isOpen else { return }
        isOpen = true
        NowPlayingModel.shared.refresh()
    }

    func close() {
        hoverCloseTask?.cancel()
        dragCloseTask?.cancel()
        dragCloseTask = nil
        gestureTravel = 0
        openedForDrag = false
        isShelfDropTargeted = false
        guard isOpen else { return }
        previewItem = nil
        isOpen = false
    }

    func toggle(tab: NotchTab? = nil) {
        if isOpen, tab == nil || tab == self.tab {
            close()
        } else {
            open(tab: tab)
        }
    }

    func hoverChanged(_ inside: Bool) {
        guard Settings.shared.openOnHover, !isConcealed else { return }
        hoverCloseTask?.cancel()
        if inside {
            // Hover tracking is back, so it owns closing again.
            openedForDrag = false
            dragCloseTask?.cancel()
            dragCloseTask = nil
            guard !isFullscreenCovered else { return }
            hoverCloseTask = Task { [weak self] in
                // Small dwell so a cursor crossing the notch does not open it.
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.open()
            }
        } else {
            hoverCloseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                guard self?.previewItem == nil else { return }
                self?.close()
            }
        }
    }

    // MARK: - File drags

    /// A file drag reached the notch: open straight onto the shelf.
    func fileDragEntered() {
        hoverCloseTask?.cancel()
        guard !isOpen || tab != .shelf else { return }
        if !isOpen { openedForDrag = true }
        previewItem = nil
        open(tab: .shelf)
    }

    /// Pointer position relative to a panel opened by a drag, reported by the
    /// pointer monitor. Leaving closes it after the same grace as hover does;
    /// coming back in time keeps it open.
    func dragPointerMoved(inside: Bool) {
        guard isOpen, openedForDrag else { return }
        if inside {
            dragCloseTask?.cancel()
            dragCloseTask = nil
        } else if dragCloseTask == nil {
            dragCloseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                self?.dragCloseTask = nil
                self?.close()
            }
        }
    }

    // MARK: - Pan

    /// Where a flick would come to rest if it decelerated like a scroll view.
    /// This is the exponential-decay projection Apple ships, not the textbook
    /// `v² / 2a`.
    private static func project(_ velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// A vertical pan over the notch: down opens it, up closes it.
    func pan(_ pan: NotchPan) {
        if isOpen {
            guard previewItem == nil else { return }
        } else {
            guard !isFullscreenCovered, !isConcealed else { return }
        }

        // Measure travel towards the action this state allows.
        let direction: CGFloat = isOpen ? -1 : 1
        let travel = pan.translation * direction

        // A wrong-way scroll or a finished pan just lets the panel settle back.
        guard pan.phase == .changed, travel > 0 else {
            if gestureTravel != 0 { gestureTravel = 0 }
            return
        }

        if !isOpen { hoverCloseTask?.cancel() }

        // Commit on where the pull is *heading*, not on where it is, so a short
        // flick works without travelling the whole distance.
        if travel + Self.project(pan.velocity * direction) >= Self.commitThreshold {
            if isOpen { close() } else { open() }
            return
        }

        gestureTravel = travel * direction
    }

    // MARK: - Fullscreen

    private func observeFullscreen() {
        FullscreenDetector.shared.$fullscreenDisplays
            .map { [displayID] displays in displays.contains(displayID) }
            .removeDuplicates()
            .sink { [weak self] covered in
                MainActor.assumeIsolated {
                    // Only meaningful while we float above the fullscreen window;
                    // otherwise macOS already keeps us off that space.
                    self?.isFullscreenCovered = covered && Settings.shared.showOverFullscreen
                }
            }
            .store(in: &cancellables)
    }
}
