import SwiftUI

/// Scrolls its text only when it does not fit, pausing at each end.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var color: Color = Theme.primaryText
    /// Size-specific letter-spacing; see `Theme.tracking(forSize:)`.
    var tracking: CGFloat = 0
    /// Points per second.
    var speed: Double = 26
    /// Pause at each end of the travel.
    var dwell: Double = 1.6

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    /// How far the text has slid, 0…overflow. Applied negatively and clamped,
    /// so the text can only ever sit at or left of its home position — no
    /// animation curve can push it out to the right.
    @State private var travelled: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    /// Restarting the cycle depends on the text and on how far it has to go.
    private struct Run: Equatable {
        var text: String
        var overflow: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { inner in
                        Color.clear
                            .onAppear { textWidth = inner.size.width }
                            .onChange(of: inner.size.width) { textWidth = $1 }
                    }
                )
                .offset(x: -min(overflow, max(0, travelled)))
                .frame(width: geo.size.width, alignment: .leading)
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { containerWidth = $1 }
        }
        .clipped()
        // Two bounded animations per cycle, instead of `repeatForever(
        // autoreverses:)` over a delayed curve. That construction has no exact
        // endpoints, and the value it presents can land outside them — which
        // shows up as the text sitting on the wrong side of its box. Keyed on
        // the run, so the loop dies with the view instead of ticking forever
        // behind a closed panel.
        .task(id: Run(text: text, overflow: overflow)) { await cycle() }
    }

    private func cycle() async {
        travelled = 0
        guard overflow > 1 else { return }
        let duration = Double(overflow) / speed

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: duration)) { travelled = overflow }

            try? await Task.sleep(for: .seconds(duration + dwell))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: duration)) { travelled = 0 }

            try? await Task.sleep(for: .seconds(duration))
        }
    }
}
