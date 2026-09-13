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
    }

    /// Pinned to the full open size, so the growing shape reveals it instead of
    /// squeezing it through a hundred intermediate layouts.
    private var openContent: some View {
        VStack(spacing: 10) {
            NotchHeader()
                .frame(height: max(28, controller.closedSize.height))

            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
    }
}

private struct NotchHeader: View {
    @EnvironmentObject var controller: NotchController
    @ObservedObject var store = ClipStore.shared
    @ObservedObject var queue = PasteQueue.shared

    /// Lets the selected pill's capsule slide between tabs instead of one
    /// fading out where the other fades in.
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchTab.allCases) { tab in
                    TabPill(
                        tab: tab,
                        isSelected: controller.tab == tab,
                        badge: tab == .clipboard ? badgeText : nil,
                        selection: selection
                    ) {
                        withAnimation(Theme.snap) { controller.tab = tab }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The hardware cutout occupies this band. Nothing may be laid out
            // in it: the camera housing physically covers whatever lands here,
            // so a control placed under it can be neither seen nor clicked.
            Color.clear
                .frame(width: controller.closedSize.width)

            HeaderIcon(symbol: "xmark") { controller.close() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var badgeText: String? {
        if queue.isActive { return "\(queue.queue.count)" }
        return store.items.isEmpty ? nil : "\(store.items.count)"
    }
}

private struct TabPill: View {
    let tab: NotchTab
    let isSelected: Bool
    let badge: String?
    let selection: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .semibold))

                // Only the active tab spells itself out. Both labels at once do
                // not fit in the flank beside the cutout, and whichever one
                // loses gets laid out under the camera housing.
                if isSelected {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(Theme.tracking(forSize: 12))
                        .fixedSize()
                }

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
            }
            .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Theme.cardFillHover)
                        .matchedGeometryEffect(id: "tabSelection", in: selection)
                } else {
                    // A faint fill even when idle, so an icon-only tab still
                    // reads as a control instead of a loose glyph.
                    Capsule(style: .continuous)
                        .fill(isHovering ? Theme.cardFill : Color.white.opacity(0.04))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: isHovering)
        .onHover { isHovering = $0 }
        .help(tab.title)
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
