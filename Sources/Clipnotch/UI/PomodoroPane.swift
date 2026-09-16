import AppKit
import SwiftUI

struct PomodoroPane: View {
    @ObservedObject var timer = PomodoroTimer.shared
    @ObservedObject var chime = ChimePlayer.shared

    var body: some View {
        HStack(spacing: 28) {
            PomodoroDial(timer: timer, diameter: 140)

            VStack(alignment: .leading, spacing: 12) {
                PhasePicker(timer: timer)
                rounds
                controls
                DurationStepper(timer: timer)
            }
            .frame(width: 290, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rounds: some View {
        let tint = PomodoroTimer.Phase.focus.tint
        let current = timer.phase == .focus ? timer.completedRounds : -1

        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<PomodoroTimer.roundsPerCycle, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index < timer.completedRounds ? tint : Color.white.opacity(0.1))
                        .overlay {
                            if index == current {
                                Capsule(style: .continuous).strokeBorder(tint.opacity(0.7), lineWidth: 1)
                            }
                        }
                        // The round in progress is wider, so "where am I" reads
                        // without counting.
                        .frame(width: index == current ? 18 : 7, height: 7)
                }
            }
            Text(roundLabel)
                .font(.system(size: 10.5, weight: .medium))
                .tracking(Theme.tracking(forSize: 10.5))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .animation(Theme.snap, value: timer.completedRounds)
        .animation(Theme.snap, value: timer.phase)
    }

    private var roundLabel: String {
        let rounds = PomodoroTimer.roundsPerCycle
        switch timer.phase {
        case .focus:
            return String(localized: "Round \(timer.completedRounds + 1) of \(rounds)")
        case .shortBreak:
            return String(localized: "Up next: round \(timer.completedRounds + 1)")
        case .longBreak:
            return String(localized: "Cycle complete")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TransportButton(symbol: "arrow.counterclockwise", glyph: 12, side: 34, action: timer.reset)
                .help(String(localized: "Reset"))
                .opacity(timer.hasProgress ? 1 : 0.4)
                .disabled(!timer.hasProgress)
            TransportButton(
                symbol: timer.isRunning(timer.phase) ? "pause.fill" : "play.fill",
                glyph: 16,
                side: 44,
                prominent: true,
                tint: timer.phase.tint,
                action: timer.toggle
            )
            .help(timer.isRunning(timer.phase) ? String(localized: "Pause") : String(localized: "Start"))
            TransportButton(symbol: "forward.end.fill", glyph: 12, side: 34, action: timer.skip)
                .help(String(localized: "Skip"))

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 18)

            TransportButton(
                symbol: chime.isPlaying ? "stop.fill" : "bell",
                glyph: 12,
                side: 34,
                action: chime.toggle
            )
            .symbolEffect(.variableColor.iterative, isActive: chime.isPlaying)
            .help(chime.isPlaying ? String(localized: "Stop Sound") : String(localized: "Play Sound"))
        }
        .animation(Theme.snap, value: timer.runningPhase)
        .animation(Theme.snap, value: chime.isPlaying)
        .animation(.easeInOut(duration: 0.4), value: timer.phase)
    }
}

/// The phase on one face: the ring is full when the phase starts and drains
/// to nothing as it runs, so a five-minute break reads exactly like a
/// twenty-five-minute focus round. The length itself is set from the stepper
/// beside it, not by winding the dial.
struct PomodoroDial: View {
    @ObservedObject var timer: PomodoroTimer
    let diameter: CGFloat

    private var lineWidth: CGFloat { diameter * 0.055 }
    /// The dial shows the phase the pane is on, so it only ticks when that
    /// phase is the one running.
    private var isTicking: Bool { timer.isRunning(timer.phase) }

    var body: some View {
        // Frame-rate updates only while running; a stopped dial is a still image.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isTicking)) { context in
            let remaining = timer.remaining(of: timer.phase, at: context.date)
            let breath = isTicking
                ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / 2) + 1) / 2
                : 0

            dial(remaining: remaining, breath: breath)
        }
        .frame(width: diameter, height: diameter)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: timer.finishCount) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(1.08, duration: 0.22, spring: .snappy)
            SpringKeyframe(0.97, duration: 0.2, spring: .snappy)
            SpringKeyframe(1, duration: 0.45, spring: .bouncy)
        }
    }

    private func dial(remaining: TimeInterval, breath: Double) -> some View {
        let tint = timer.phase.tint
        let radius = (diameter - lineWidth) / 2
        let total = timer.duration(of: timer.phase)
        let left = total > 0 ? min(max(remaining / total, 0), 1) : 0

        return ZStack {
            // Glow that breathes behind the ring while the clock runs.
            Circle()
                .fill(tint)
                .frame(width: diameter * 0.72, height: diameter * 0.72)
                .blur(radius: diameter * 0.2)
                .opacity(isTicking ? 0.14 + 0.12 * breath : 0.05)

            Ticks(count: timer.minutes(of: timer.phase), lit: left, tint: tint)
                .padding(lineWidth * 2.1)

            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: lineWidth)

            arc(to: left, tint: tint)

            // Leading edge, lit like the tip of a fuse.
            Circle()
                .fill(Color.white)
                .frame(width: lineWidth * 1.35, height: lineWidth * 1.35)
                .shadow(color: tint, radius: isTicking ? 4 + 3 * breath : 2)
                .offset(y: -radius)
                .rotationEffect(.degrees(360 * left))
                .opacity(remaining > 0 ? 1 : 0)

            VStack(spacing: 2) {
                let size = diameter * (remaining >= 3600 ? 0.16 : 0.21)
                Text(PomodoroTimer.format(remaining))
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
                    .contentTransition(.numericText(countsDown: isTicking))
                    .animation(Theme.snap, value: Int(remaining.rounded(.up)))

                Text(timer.phase.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: diameter * 0.68)
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: timer.revision)
        .animation(.easeInOut(duration: 0.5), value: timer.phase)
    }

    private func arc(to fraction: Double, tint: Color) -> some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(
                AngularGradient(
                    colors: [tint.opacity(0.4), tint],
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(360 * max(fraction, 0.001))
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
    }
}

/// Marks inside the ring; the ones covered by the arc are lit. One per minute
/// of the phase, so a short break gets a coarse scale rather than a crowded
/// hour face, down to a floor that keeps a one-minute phase from having a
/// single mark.
private struct Ticks: View {
    /// Minutes in the phase.
    let count: Int
    /// Remaining time as a fraction of the phase.
    let lit: Double
    let tint: Color

    private var marks: Int { min(max(count, 12), 60) }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2
            let count = marks
            let litCount = Int((lit * Double(count)).rounded(.up))

            for index in 0..<count {
                let major = index % 5 == 0
                let length: CGFloat = major ? 5 : 2.5
                let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
                let direction = CGPoint(x: cos(angle), y: sin(angle))

                var path = Path()
                path.move(to: CGPoint(x: center.x + direction.x * outer,
                                      y: center.y + direction.y * outer))
                path.addLine(to: CGPoint(x: center.x + direction.x * (outer - length),
                                         y: center.y + direction.y * (outer - length)))

                let opacity: Double = index < litCount ? (major ? 0.5 : 0.28) : 0.08
                context.stroke(path, with: .color(.white.opacity(opacity)),
                               style: StrokeStyle(lineWidth: major ? 1.3 : 1, lineCap: .round))
            }
        }
    }
}

private struct PhasePicker: View {
    @ObservedObject var timer: PomodoroTimer
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PomodoroTimer.Phase.allCases) { phase in
                let isSelected = timer.phase == phase
                Button {
                    withAnimation(Theme.snap) { timer.select(phase) }
                } label: {
                    Text(phase.title)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(Theme.tracking(forSize: 11))
                        .foregroundStyle(isSelected ? phase.tint : Theme.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(phase.tint.opacity(0.16))
                                    .matchedGeometryEffect(id: "phase", in: selection)
                            }
                        }
                        // A phase keeps running while another one is on show,
                        // and the dial cannot say so: the dot does.
                        .overlay(alignment: .topTrailing) {
                            if timer.isRunning(phase) && !isSelected {
                                Circle()
                                    .fill(phase.tint)
                                    .frame(width: 5, height: 5)
                                    .offset(x: -1, y: 1)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
        .animation(Theme.snap, value: timer.phase)
        .animation(Theme.snap, value: timer.runningPhase)
    }
}

/// Sets the current phase's length, in whole minutes, as a number rather than
/// as an angle. The panel is a non-activating window and never becomes key, so
/// a text field could not be typed into: the value is driven by a pair of
/// buttons that repeat, and then accelerate, while held.
private struct DurationStepper: View {
    @ObservedObject var timer: PomodoroTimer

    private var minutes: Int { timer.minutes(of: timer.phase) }

    var body: some View {
        HStack(spacing: 9) {
            Text(String(localized: "Length"))
                .font(.system(size: 10.5, weight: .medium))
                .tracking(Theme.tracking(forSize: 10.5))
                .foregroundStyle(Theme.tertiaryText)

            HStack(spacing: 2) {
                StepButton(
                    symbol: "minus",
                    enabled: minutes > PomodoroTimer.minuteRange.lowerBound,
                    help: String(localized: "Shorter")
                ) { changing(by: -$0) }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(minutes)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                    Text(String(localized: "min"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                // Fixed width, so the row does not shuffle as the number grows
                // a digit under a held button.
                .frame(width: 54)

                StepButton(
                    symbol: "plus",
                    enabled: minutes < PomodoroTimer.minuteRange.upperBound,
                    help: String(localized: "Longer")
                ) { changing(by: $0) }
            }
            .padding(3)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
        }
        .animation(Theme.snap, value: minutes)
        .animation(Theme.snap, value: timer.phase)
    }

    /// Reports whether the nudge actually moved the value, so a held button
    /// stops buzzing once it is pinned to the end of the range.
    private func changing(by delta: Int) -> Bool {
        let before = minutes
        timer.adjustMinutes(by: delta)
        return minutes != before
    }
}

/// One end of the stepper. A press fires once, and keeps firing if it is held,
/// in bigger steps the longer the hold — an hour is reachable without sixty
/// clicks, and a single minute is still one tap.
private struct StepButton: View {
    let symbol: String
    let enabled: Bool
    let help: String
    /// Returns false once the value can go no further.
    let step: (Int) -> Bool

    @State private var isHovering = false
    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(enabled ? Theme.primaryText : Theme.tertiaryText)
            .frame(width: 26, height: 26)
            .background(
                Circle().fill(
                    isPressed && enabled
                        ? Theme.cardFillHover
                        : (isHovering && enabled ? Theme.cardFill : Color.clear)
                )
            )
            .contentShape(Circle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        begin()
                    }
                    .onEnded { _ in
                        isPressed = false
                        repeatTask?.cancel()
                        repeatTask = nil
                    }
            )
            .onDisappear {
                repeatTask?.cancel()
                repeatTask = nil
            }
            .animation(Theme.quick, value: isHovering)
            .animation(Theme.quick, value: isPressed)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(help)
            .help(help)
    }

    private func begin() {
        guard enabled else { return }
        fire(1)
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            // A beat before the repeat starts, so a plain click stays a click.
            try? await Task.sleep(for: .milliseconds(420))
            var ticks = 0
            while !Task.isCancelled {
                ticks += 1
                let fast = ticks > 10
                guard fire(fast ? 5 : 1) else { break }
                try? await Task.sleep(for: .milliseconds(fast ? 110 : 75))
            }
        }
    }

    @discardableResult
    private func fire(_ delta: Int) -> Bool {
        guard step(delta) else { return false }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return true
    }
}
