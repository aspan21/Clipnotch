import SwiftUI

/// Root of one display's panel.
///
/// The window is always the full expanded size. Inside it, one animatable frame
/// grows from the closed strip to the open panel, and because the parent centres
/// that frame both edges travel outward together — the panel unfolds from the
/// middle and folds back into it.
///
/// Both content states are laid out at their *final* size and revealed by the
/// growing shape rather than reflowed inside it. That is what keeps the motion
/// smooth: one frame interpolates, nothing below it relayouts per frame.
///
/// Hit-testing is limited to the drawn shape, so the rest of the window stays
/// click-through.
struct NotchRootView: View {
    @ObservedObject var controller: NotchController
    @ObservedObject var media = NowPlayingModel.shared
    @ObservedObject var queue = PasteQueue.shared
    @ObservedObject var pomodoro = PomodoroTimer.shared
    @ObservedObject var menuBar = MenuBarObstruction.shared

    /// Ties the closed strip's album art to the open panel's, so the artwork
    /// flies between the two instead of one fading out while the other fades in.
    @Namespace private var artwork

    @State private var isHovering = false

    /// Everything the resize spring is allowed to key on, in one value — so a
    /// single spring owns the transition instead of several fighting over it.
    private struct Metrics: Equatable {
        var size: CGSize
        var isOpen: Bool
    }

    var body: some View {
        let metrics = Metrics(size: controller.currentSize, isOpen: controller.isOpen)
        let concealed = controller.isConcealed
        let radii = controller.cornerRadii
        let pull = controller.gesturePull

        ZStack(alignment: .top) {
            panel(size: metrics.size, radii: radii)
                // Growing towards the pull telegraphs where the gesture is
                // going; a separate spring, because it tracks the pointer and
                // has to stay interruptible.
                .scaleEffect(1 + pull * 0.12, anchor: .top)
                .animation(Theme.gesture, value: pull)
                // On a display without a cutout the collapsed panel is not just
                // zero-height: it must not hit-test either, or it would eat
                // clicks aimed at the tabs and toolbars sitting underneath.
                .opacity(concealed ? 0 : 1)
                .allowsHitTesting(!concealed)
        }
        .frame(width: NotchGeometry.windowSize.width,
               height: NotchGeometry.windowSize.height,
               alignment: .top)
        // Outside the frame that centres the panel, on purpose: the panel's
        // *position* is decided by this layout, so an animation scoped any
        // deeper interpolates the width while the left edge snaps straight to
        // its final spot — which reads as the panel opening leftwards first.
        .animation(controller.resizeAnimation, value: metrics)
        .environmentObject(controller)
        .preferredColorScheme(.dark)
    }

    private func panel(size: CGSize, radii: (top: CGFloat, bottom: CGFloat)) -> some View {
        ZStack(alignment: .top) {
            Theme.panel

            if controller.isOpen {
                // A preview replaces the pane rather than covering it: the
                // panel grows to its own size for it, so there is nothing left
                // underneath worth dimming.
                if let item = controller.previewItem {
                    ClipPreview(item: item) {
                        withAnimation(controller.resizeAnimation) {
                            controller.previewItem = nil
                        }
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.16)))
                } else {
                    openContent
                        .transition(
                            .opacity
                                .combined(with: .scale(scale: 0.94))
                                .animation(.easeOut(duration: 0.2))
                        )
                }
            } else {
                closedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        // The one animatable frame. `.top` keeps it horizontally centred, so
        // the shape opens and closes symmetrically about the cutout.
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
        // A black panel on a dark desktop has no visible boundary of its own.
        // The hairline gives it one — brighter along the top, the way an edge
        // catches light, fading out towards the bottom.
        .overlay {
            NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
                .stroke(
                    LinearGradient(
                        // Brightest along the bottom, because that is the
                        // edge you can actually see: the top one lives under
                        // the hardware cutout.
                        colors: [Color.white.opacity(0.08), Color.white.opacity(0.24)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                // A stroke straddles its path, so inset the shape by half the
                // line to keep the whole hairline inside the panel.
                .padding(0.5)
                .opacity(controller.isOpen || isHovering ? 1 : 0)
        }
        // Drawn last, so the panel's top still merges into the hardware cutout
        // instead of being outlined against it.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.panel)
                .frame(height: 1)
                .padding(.horizontal, radii.top)
        }
        // One shadow for the whole silhouette rather than one per subview.
        .compositingGroup()
        .shadow(
            color: .black.opacity(controller.isOpen || isHovering ? 0.6 : 0),
            radius: 12,
            y: 6
        )
        .contentShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
        .onHover { hovering in
            isHovering = hovering
            controller.hoverChanged(hovering)
        }
        .onTapGesture {
            if !controller.isOpen { controller.open() }
        }
        .notchPan { controller.pan($0) }
        // Files dropped anywhere on the panel land on the shelf, closed strip
        // included — reaching it is enough to open it.
        .onDrop(of: [.fileURL], delegate: ShelfDropDelegate(controller: controller))
    }

    /// Pinned to the full open size, so the growing shape reveals it instead of
    /// squeezing it through a hundred intermediate layouts.
    ///
    /// The menu runs down the left edge and a column of the same width mirrors
    /// it on the right, so the pane stays centred on the cutout's axis.
    private var openContent: some View {
        HStack(alignment: .top, spacing: Self.railSpacing) {
            NotchSidebar()
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity)

            VStack(spacing: 10) {
                // The hardware cutout occupies this band; nothing goes here.
                Color.clear
                    .frame(height: controller.headerHeight)

                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HeaderIcon(symbol: "xmark") { controller.close() }
                .frame(width: Self.railWidth, height: controller.headerHeight)
        }
        .padding(.horizontal, NotchGeometry.contentInset(forTopRadius: NotchGeometry.cornerRadii.open.top))
        .padding(.top, 6)
        .padding(.bottom, Theme.contentGutter)
        .frame(width: NotchGeometry.openSize.width, height: NotchGeometry.openSize.height)
    }

    private var closedContent: some View {
        ClosedContentView(artworkNamespace: artwork)
            .frame(width: controller.effectiveClosedSize.width,
                   height: controller.effectiveClosedHeight)
    }

    @ViewBuilder
    private var pane: some View {
        switch controller.tab {
        case .nowPlaying: NowPlayingPane(artworkNamespace: artwork)
        case .clipboard: ClipboardPane()
        case .shelf: ShelfPane()
        case .pomodoro: PomodoroPane()
        }
    }

    private static let railWidth: CGFloat = 32
    private static let railSpacing: CGFloat = 10
}

/// Icon-only tab rail. The selection slides between icons rather than
/// fading from one to the next.
private struct NotchSidebar: View {
    @EnvironmentObject var controller: NotchController
    @ObservedObject var queue = PasteQueue.shared
    @ObservedObject var shelf = ShelfStore.shared
    @ObservedObject var pomodoro = PomodoroTimer.shared
    @ObservedObject var menuBar = MenuBarObstruction.shared

    @Namespace private var selection

    var body: some View {
        VStack(spacing: 4) {
            ForEach(NotchTab.allCases) { tab in
                SidebarButton(
                    tab: tab,
                    isSelected: controller.tab == tab,
                    badge: badge(for: tab),
                    selection: selection
                ) {
                    withAnimation(Theme.snap) {
                        controller.previewItem = nil
                        controller.tab = tab
                    }
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func badge(for tab: NotchTab) -> SidebarBadge? {
        switch tab {
        case .clipboard:
            return queue.isActive ? .count(queue.queue.count, Theme.accent) : nil
        case .shelf:
            return shelf.items.isEmpty ? nil : .count(shelf.items.count, Theme.primaryText)
        case .pomodoro:
            return pomodoro.runningPhase.map { .dot($0.tint) }
        case .nowPlaying:
            return nil
        }
    }
}

private enum SidebarBadge: Equatable {
    case count(Int, Color)
    case dot(Color)
}

private struct SidebarButton: View {
    let tab: NotchTab
    let isSelected: Bool
    let badge: SidebarBadge?
    let selection: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    private static let side: CGFloat = 26

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.primaryText : (isHovering ? Theme.primaryText.opacity(0.8) : Theme.secondaryText))
                .frame(width: Self.side, height: Self.side)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.cardFillHover)
                            .matchedGeometryEffect(id: "tabSelection", in: selection)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.cardFill)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { badgeView }
        .animation(Theme.quick, value: isHovering)
        .animation(Theme.snap, value: badge)
        .onHover { isHovering = $0 }
        .help(tab.title)
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .count(let count, let tint):
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 13, minHeight: 13)
                .background(Capsule().fill(tint))
                .overlay(Capsule().strokeBorder(Theme.panel, lineWidth: 1.5))
                .fixedSize()
                .offset(x: 5, y: -4)
                .contentTransition(.numericText())
                .transition(.scale.combined(with: .opacity))
                .allowsHitTesting(false)
        case .dot(let tint):
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
                .offset(x: 2, y: -1)
                .transition(.scale.combined(with: .opacity))
                .allowsHitTesting(false)
        case nil:
            EmptyView()
        }
    }
}

/// Routes file drops onto the shelf. Rejects drags that started on the shelf
/// itself, so pulling a file out and letting go over the notch is a no-op.
private struct ShelfDropDelegate: DropDelegate {
    let controller: NotchController

    func validateDrop(info: DropInfo) -> Bool {
        !ShelfDragSource.shared.isDragging && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        controller.fileDragEntered()
        controller.isShelfDropTargeted = true
    }

    func dropExited(info: DropInfo) {
        controller.isShelfDropTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        controller.isShelfDropTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        ShelfStore.loadURLs(from: providers) { urls in
            withAnimation(Theme.snap) { ShelfStore.shared.add(urls) }
        }
        return true
    }
}

private struct HeaderIcon: View {
    let symbol: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Theme.primaryText : Theme.secondaryText)
                // 28pt: a pointer target you do not have to aim at.
                .frame(width: 28, height: 28)
                .background(Circle().fill(isHovering ? Theme.cardFill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: isHovering)
        .onHover { isHovering = $0 }
    }
}
