import AppKit
import SwiftUI

struct PomodoroPane: View {
    @ObservedObject var timer = PomodoroTimer.shared
    @ObservedObject var chime = ChimePlayer.shared

    var body: some View {
        HStack(spacing: 28) {
            PomodoroDial(timer: timer, diameter: 140)

            VStack(alignment: .leading, spacing: 14) {
                PhasePicker(timer: timer)
                rounds
                controls
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
                symbol: timer.isRunning ? "pause.fill" : "play.fill",
                glyph: 16,
                side: 44,
                prominent: true,
                tint: timer.phase.tint,
                action: timer.toggle
            )
            .help(timer.isRunning ? String(localized: "Pause") : String(localized: "Start"))
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
        .animation(Theme.snap, value: timer.isRunning)
        .animation(Theme.snap, value: chime.isPlaying)
        .animation(.easeInOut(duration: 0.4), value: timer.phase)
    }
}

/// A sixty-minute face, like a kitchen timer: the arc runs from twelve
/// o'clock to the time left, and drains back towards twelve as the clock runs.
/// While stopped, dragging round the ring sets the time; a second lap goes
/// past the hour.
struct PomodoroDial: View {
    @ObservedObject var timer: PomodoroTimer
    let diameter: CGFloat

    @State private var isHovering = false
    @State private var isDragging = false
    /// Minutes under the pointer during a drag, fractional; carries the lap.
    @State private var dragMinutes: Double = 0
    @State private var lastAngle: Double?
    @State private var hasPushedCursor = false

    private var lineWidth: CGFloat { diameter * 0.055 }
    private var isAdjustable: Bool { !timer.isRunning }

    var body: some View {
        // Frame-rate updates only while running; a stopped dial is a still image.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !timer.isRunning)) { context in
            let remaining = timer.remaining(at: context.date)
            let breath = timer.isRunning
                ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / 2) + 1) / 2
                : 0

            dial(remaining: remaining, breath: breath)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(setTimeGesture)
        .onHover { hovering in
            isHovering = hovering
            updateCursor()
        }
        .onChange(of: timer.isRunning) { _, _ in updateCursor() }
        .onDisappear {
            isHovering = false
            updateCursor()
        }
        .help(isAdjustable ? String(localized: "Drag around the ring to set the time") : "")
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
        let face = remaining / 3600
        let lap = min(face, 1)
        let extra = max(0, min(face - 1, 1))
        let head = face > 1 ? extra : lap
        let grabbable = isAdjustable && (isHovering || isDragging)

        return ZStack {
            // Glow that breathes behind the ring while the clock runs.
            Circle()
                .fill(tint)
                .frame(width: diameter * 0.72, height: diameter * 0.72)
                .blur(radius: diameter * 0.2)
                .opacity(timer.isRunning ? 0.14 + 0.12 * breath : 0.05)

            Ticks(lit: face, tint: tint)
                .padding(lineWidth * 2.1)

            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: lineWidth)

            arc(to: lap, tint: tint, dimmed: face > 1)
            if face > 1 {
                arc(to: extra, tint: tint, dimmed: false)
            }

            // Leading edge, lit like the tip of a fuse. Doubles as the handle.
            Circle()
                .fill(Color.white)
                .frame(width: lineWidth * (grabbable ? 1.8 : 1.35),
                       height: lineWidth * (grabbable ? 1.8 : 1.35))
                .shadow(color: tint, radius: timer.isRunning ? 4 + 3 * breath : (grabbable ? 6 : 2))
                .offset(y: -radius)
                .rotationEffect(.degrees(360 * head))
                .opacity(remaining > 0 ? 1 : 0)

            VStack(spacing: 2) {
                let size = diameter * (remaining >= 3600 ? 0.16 : 0.21)
                Text(PomodoroTimer.format(remaining))
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
                    .contentTransition(.numericText(countsDown: timer.isRunning))
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
        .animation(Theme.quick, value: grabbable)
        .animation(isDragging ? .interactiveSpring(response: 0.18, dampingFraction: 1) : nil, value: timer.pausedRemaining)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: timer.revision)
        .animation(.easeInOut(duration: 0.5), value: timer.phase)
    }

    private func arc(to fraction: Double, tint: Color, dimmed: Bool) -> some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(
                AngularGradient(
                    colors: dimmed ? [tint.opacity(0.35), tint.opacity(0.35)] : [tint.opacity(0.4), tint],
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(360 * max(fraction, 0.001))
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
    }

    // MARK: - Setting the time

    /// Open hand over a dial that can be wound; kept balanced, since an
    /// unmatched pop would take someone else's cursor off the stack.
    private func updateCursor() {
        let wanted = isHovering && isAdjustable
        guard wanted != hasPushedCursor else { return }
        if wanted { NSCursor.openHand.push() } else { NSCursor.pop() }
        hasPushedCursor = wanted
    }

    private var setTimeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isAdjustable else { return }
                let angle = Self.angle(of: value.location, in: diameter)

                if let previous = lastAngle {
                    // Accumulate the change rather than reading the absolute
                    // angle, so crossing twelve o'clock keeps winding instead
                    // of jumping back to zero.
                    var delta = angle - previous
                    if delta > 180 { delta -= 360 }
                    if delta < -180 { delta += 360 }
                    dragMinutes += delta / 6
                } else {
                    // First touch jumps to where the pointer is, within the
                    // current lap.
                    let current = Double(timer.minutes(of: timer.phase))
                    let lapBase = current > 60 ? 60.0 : 0
                    dragMinutes = lapBase + angle / 6
                    isDragging = true
                }
                lastAngle = angle

                let range = PomodoroTimer.minuteRange
                dragMinutes = min(max(dragMinutes, Double(range.lowerBound)), Double(range.upperBound))
                let minutes = Int(dragMinutes.rounded())
                if minutes != timer.minutes(of: timer.phase) {
                    timer.setMinutes(minutes)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .onEnded { _ in
                lastAngle = nil
                isDragging = false
            }
    }

    /// Clockwise degrees from twelve o'clock, 0..<360.
    private static func angle(of point: CGPoint, in diameter: CGFloat) -> Double {
        let dx = Double(point.x - diameter / 2)
        let dy = Double(point.y - diameter / 2)
        let degrees = atan2(dx, -dy) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}

/// Minute marks inside the ring; the ones covered by the arc are lit.
private struct Ticks: View {
    /// Remaining time as a fraction of the hour; past 1 everything is lit.
    let lit: Double
    let tint: Color

    private static let count = 60

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2
            let litCount = Int((lit * Double(Self.count)).rounded(.up))

            for index in 0..<Self.count {
                let major = index % 5 == 0
                let length: CGFloat = major ? 5 : 2.5
                let angle = Double(index) / Double(Self.count) * 2 * .pi - .pi / 2
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
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
        .animation(Theme.snap, value: timer.phase)
    }
}
