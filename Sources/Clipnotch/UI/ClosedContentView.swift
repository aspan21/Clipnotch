import SwiftUI

/// What shows while the panel is collapsed. On a notched Mac the middle of this
/// strip is behind the hardware cutout, so all content lives in the two flanks.
struct ClosedContentView: View {
    let artworkNamespace: Namespace.ID

    @EnvironmentObject var controller: NotchController
    @ObservedObject var media = NowPlayingModel.shared
    @ObservedObject var queue = PasteQueue.shared

    var body: some View {
        // Two flanks plus the cutout add up to `effectiveClosedSize.width`
        // exactly: no padding, no minimum-length spacer, nothing to squeeze.
        HStack(spacing: 0) {
            leftFlank
                .frame(width: controller.activeFlankWidth)
            Color.clear
                .frame(width: controller.closedSize.width)
            rightFlank
                .frame(width: controller.activeFlankWidth)
        }
        .frame(height: controller.effectiveClosedHeight)
    }

    private var side: CGFloat { controller.closedContentSize }

    private var leftFlank: some View {
        Group {
            if let artwork = media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .matchedGeometryEffect(
                        id: Theme.artworkGeometryID,
                        in: artworkNamespace,
                        isSource: !controller.isOpen
                    )
            } else if media.snapshot.hasTrack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.cardFill)
                    .frame(width: side, height: side)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: max(6, side * 0.45), weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    )
                    .matchedGeometryEffect(
                        id: Theme.artworkGeometryID,
                        in: artworkNamespace,
                        isSource: !controller.isOpen
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var rightFlank: some View {
        Group {
            if queue.isActive {
                QueuePip(count: queue.queue.count, side: side)
            } else if media.snapshot.hasTrack {
                PlaybackIndicator(isPlaying: media.snapshot.isPlaying, tint: media.artworkAccent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Count badge shown while a paste queue is armed.
private struct QueuePip: View {
    let count: Int
    let side: CGFloat

    var body: some View {
        Text("\(count)")
            .font(.system(size: max(7, side * 0.5), weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: side, height: side)
            .background(Circle().fill(Theme.accent))
            .transition(.scale.combined(with: .opacity))
    }
}

/// Bars that breathe while audio plays, and a pause glyph when it does not.
///
/// Flattening the bars instead reads as three stray dots — and in the artwork's
/// accent colour they look like somebody else's status light, not like paused
/// playback.
private struct PlaybackIndicator: View {
    let isPlaying: Bool
    let tint: Color

    @State private var phase: Double = 0

    var body: some View {
        Group {
            if isPlaying {
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(tint)
                            .frame(width: 2.5, height: height(for: index))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: phase)
            } else {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    // Muted: idle state, not something asking for attention.
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(height: 14, alignment: .center)
        // Keyed on `isPlaying`, so the loop is torn down while paused instead of
        // waking every 180ms to discard its own tick.
        .task(id: isPlaying) {
            guard isPlaying else {
                phase = 0
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                phase += 0.25
            }
        }
    }

    private func height(for index: Int) -> CGFloat {
        let offsets: [Double] = [0, 0.66, 0.33]
        let value = sin((phase + offsets[index]) * .pi * 2)
        return 4 + CGFloat((value + 1) / 2) * 9
    }
}
