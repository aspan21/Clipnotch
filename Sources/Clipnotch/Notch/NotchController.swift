import AppKit
import Combine
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case nowPlaying
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .clipboard: return "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .clipboard: return "square.on.square.dashed"
        }
    }
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

    /// Points of pull that commit to opening or closing.
    static let commitThreshold: CGFloat = 120
    /// Gap between the closed notch's live content and the outer edge.
    static let flankGutter: CGFloat = 10
    /// How much shorter the closed content is than the cutout it sits beside.
    static let closedContentInset: CGFloat = 12

    private var hoverCloseTask: Task<Void, Never>?
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
        hasClosedContent ? flankWidth : 0
    }

    var hasClosedContent: Bool {
        guard !isFullscreenCovered, !isConcealed else { return false }
        return NowPlayingModel.shared.snapshot.hasTrack || PasteQueue.shared.isActive
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
        gestureTravel = 0
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
