import SwiftUI

struct ClipboardPane: View {
    @ObservedObject var store = ClipStore.shared
    @ObservedObject var queue = PasteQueue.shared
    @ObservedObject var access = AccessibilityGuard.shared
    @EnvironmentObject var controller: NotchController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QueueBar()

            if store.items.isEmpty {
                EmptyStateView(
                    symbol: "square.on.square.dashed",
                    title: "Clipboard is empty",
                    detail: "Copy anything — screenshots, text, files — and it lands here."
                )
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(store.items) { item in
                    ClipCard(
                        item: item,
                        queuePosition: queue.position(of: item),
                        onTap: { handleTap(item) },
                        onPreview: { controller.previewItem = item },
                        onDelete: {
                            withAnimation(Theme.snap) { store.delete(item) }
                        }
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .frame(height: Theme.cardSize.height + 12)
        // Fades where the strip meets the panel edge, so the row reads as
        // continuing rather than being chopped off.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.02),
                    .init(color: .black, location: 0.98),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func handleTap(_ item: ClipItem) {
        guard access.isTrusted else {
            // No tap permission, so no sequencing: fall back to a plain copy.
            queue.copyWithoutQueue(item)
            return
        }
        withAnimation(Theme.snap) { queue.toggle(item) }
    }
}
