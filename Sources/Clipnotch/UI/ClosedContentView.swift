import SwiftUI

/// What shows while the panel is collapsed. On a notched Mac the middle of this
/// strip is behind the hardware cutout, so all content lives in the two flanks.
struct ClosedContentView: View {
    let artworkNamespace: Namespace.ID

    @EnvironmentObject var controller: NotchController
    @ObservedObject var media = NowPlayingModel.shared
    @ObservedObject var queue = PasteQueue.shared
    @ObservedObject var pomodoro = PomodoroTimer.shared

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
            switch controller.closedActivity {
            case .pomodoro:
                PomodoroPip(timer: pomodoro, side: side)
            case .pasteQueue, .media:
                if media.isLive { artwork }
            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var artwork: some View {
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
        // Dims during the pause linger, just before the flanks fold away.
        .opacity(media.snapshot.isPlaying ? 1 : 0.55)
        .animation(Theme.quick, value: media.snapshot.isPlaying)
    }

    private var rightFlank: some View {
        Group {
            switch controller.closedActivity {
            case .pasteQueue:
                QueuePip(count: queue.queue.count, side: side)
            case .pomodoro:
                PomodoroClock(timer: pomodoro)
            case .media:
                PlaybackIndicator(isPlaying: media.snapshot.isPlaying, tint: media.artworkAccent)
            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Small ring that drains as the pomodoro phase runs; a check once it is done.
private struct PomodoroPip: View {
    @ObservedObject var timer: PomodoroTimer
    let side: CGFloat

    var body: some View {
        // The closed notch reports on the phase that is running, whatever the
        // open pane happens to be showing.
        let phase = timer.livePhase
        let tint = phase.tint
        let ring = max(4, side * 0.78)

        TimelineView(.periodic(from: .now, by: 1)) { context in
            let progress = timer.justFinished ? 0 : timer.progress(of: phase, at: context.date)
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.22), lineWidth: 2.5)
                Circle()
                    .trim(from: progress, to: 1)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                if timer.justFinished {
                    Image(systemName: "checkmark")
                        .font(.system(size: max(5, ring * 0.45), weight: .heavy))
                        .foregroundStyle(tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: ring, height: ring)
        }
        .frame(width: side, height: side)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: timer.finishCount) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(1.35, duration: 0.2, spring: .snappy)
            SpringKeyframe(1, duration: 0.5, spring: .bouncy)
        }
        .transition(.scale.combined(with: .opacity))
    }
}

/// Remaining time beside the cutout, ticking with a rolling-digit transition.
private struct PomodoroClock: View {
    @ObservedObject var timer: PomodoroTimer

    var body: some View {
        let phase = timer.livePhase

        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(of: phase, at: context.date)
            Text(timer.justFinished ? String(localized: "Done") : PomodoroTimer.format(remaining))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(phase.tint)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText(countsDown: true))
                .animation(Theme.snap, value: Int(remaining.rounded(.up)))
        }
        .transition(.opacity)
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

/// Bars that breathe while audio plays. On pause they settle flat for the few
/// seconds before the flanks fold away — never long enough to read as three
/// stray dots.
private struct PlaybackIndicator: View {
    let isPlaying: Bool
    let tint: Color

    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint.opacity(isPlaying ? 1 : 0.5))
                    .frame(width: 2.5, height: isPlaying ? height(for: index) : 3)
            }
        }
        .animation(.easeInOut(duration: isPlaying ? 0.22 : 0.35), value: phase)
        .animation(.easeInOut(duration: 0.35), value: isPlaying)
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
