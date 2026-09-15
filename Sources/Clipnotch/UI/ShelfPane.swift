import AppKit
import SwiftUI

struct ShelfPane: View {
    @ObservedObject var shelf = ShelfStore.shared
    @EnvironmentObject var controller: NotchController

    private static let tileSize = CGSize(width: 92, height: 112)

    var body: some View {
        Group {
            if shelf.items.isEmpty {
                dropZone
            } else {
                filled
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { shelf.pruneMissing() }
    }

    // MARK: - Empty

    private var dropZone: some View {
        let targeted = controller.isShelfDropTargeted
        let tint = targeted ? Theme.accent : Color.white

        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.accent.opacity(targeted ? 0.1 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(targeted ? 0.8 : 0.16),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .overlay {
                VStack(spacing: 7) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(targeted ? Theme.accent : Theme.tertiaryText)
                        .symbolEffect(.bounce, value: targeted)
                    Text(targeted ? String(localized: "Release to Add") : String(localized: "Shelf Is Empty"))
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(Theme.tracking(forSize: 13))
                        .foregroundStyle(targeted ? Theme.primaryText : Theme.secondaryText)
                        .contentTransition(.opacity)
                    Text("Drop files here, switch to another display, and drag them out from the notch.")
                        .font(.system(size: 11))
                        .tracking(Theme.tracking(forSize: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .scaleEffect(targeted ? 1.015 : 1)
            .animation(Theme.snap, value: targeted)
    }

    // MARK: - Filled

    private var filled: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(summary)
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(Theme.tracking(forSize: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .contentTransition(.numericText())
                Spacer()
                if !shelf.selection.isEmpty {
                    Button("Deselect") { shelf.selection.removeAll() }
                        .buttonStyle(PillButtonStyle(tint: Theme.secondaryText))
                        .transition(.opacity)
                }
                Button("Clear") { shelf.removeAll() }
                    .buttonStyle(PillButtonStyle())
            }
            .frame(height: 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if shelf.items.count > 1 {
                        StackTile(items: shelf.items, size: Self.tileSize)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    ForEach(shelf.items) { item in
                        ShelfTile(
                            item: item,
                            isSelected: shelf.selection.contains(item.id),
                            size: Self.tileSize
                        )
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: Self.tileSize.height)
        }
        .overlay {
            // The shelf keeps accepting drops once it has items; say so.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(controller.isShelfDropTargeted ? 0.8 : 0), lineWidth: 1.5)
                .padding(-4)
                .allowsHitTesting(false)
        }
        .animation(Theme.snap, value: shelf.items)
        .animation(Theme.snap, value: shelf.selection)
        .animation(Theme.quick, value: controller.isShelfDropTargeted)
    }

    private var summary: String {
        let count = shelf.items.count
        if !shelf.selection.isEmpty {
            return String(localized: "\(shelf.selection.count) of \(count) selected")
        }
        return String(localized: "\(count) files")
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let isSelected: Bool
    let size: CGSize

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: ShelfStore.icon(for: item.url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.18) : (isHovering ? Theme.cardFillHover : Theme.cardFill))
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Theme.cardStroke, lineWidth: isSelected ? 1.5 : 1)
        }
        .overlay {
            DragHandle(
                onClick: { ShelfStore.shared.toggleSelection(item) },
                payload: { ShelfStore.shared.dragPayload(startingAt: item) }
            )
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    ShelfStore.shared.remove([item.id])
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.black.opacity(0.75)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .transition(.opacity)
                .help("Remove from Shelf")
            }
        }
        .animation(Theme.quick, value: isHovering)
        .onHover { isHovering = $0 }
        .help(Text(verbatim: item.url.path))
    }
}

/// Carries every shelved file in one drag.
private struct StackTile: View {
    let items: [ShelfItem]
    let size: CGSize

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
                    Image(nsImage: ShelfStore.icon(for: item.url))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(Double(index) * (isHovering ? 9 : 6) - 6))
                        .offset(x: CGFloat(index) * (isHovering ? 7 : 4) - 4)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                }
            }
            .frame(width: 52, height: 52)

            Text("All \(items.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.accent.opacity(isHovering ? 0.16 : 0.09))
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .overlay {
            DragHandle(onClick: {}, payload: { ShelfStore.shared.items })
        }
        .animation(Theme.snap, value: isHovering)
        .onHover { isHovering = $0 }
        .help("Drag to move all files")
    }
}

/// AppKit mouse handling under a tile. SwiftUI's own drag API carries one
/// item per drag and cannot report where it ended; this carries the whole
/// selection and lets the shelf forget files that were delivered.
private struct DragHandle: NSViewRepresentable {
    let onClick: () -> Void
    let payload: () -> [ShelfItem]

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onClick = onClick
        view.payload = payload
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onClick = onClick
        view.payload = payload
    }

    final class HandleView: NSView {
        var onClick: () -> Void = {}
        var payload: () -> [ShelfItem] = { [] }

        /// Travel before a press turns into a drag, so a click stays a click.
        private static let dragThreshold: CGFloat = 4
        private var downEvent: NSEvent?

        // The panel never becomes key; without this the first click only
        // "activates" the window and is lost.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            downEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard hypot(dx, dy) >= Self.dragThreshold else { return }
            downEvent = nil
            MainActor.assumeIsolated {
                ShelfDragSource.shared.begin(items: payload(), event: event, from: self)
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer { downEvent = nil }
            guard downEvent != nil else { return }
            onClick()
        }
    }
}
