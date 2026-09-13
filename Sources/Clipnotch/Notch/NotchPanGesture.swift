import AppKit
import SwiftUI

enum NotchPanPhase {
    case changed
    case ended
}

/// A vertical pan over the notch. Pulling down opens the panel, pushing up
/// closes it, and the handler gets both continuously so it can respond during
/// the gesture instead of only when it ends.
struct NotchPan {
    /// Points travelled vertically since the pan started; positive is downward.
    var translation: CGFloat
    /// Points per second, positive downward, for momentum projection.
    var velocity: CGFloat
    var phase: NotchPanPhase
}

extension View {
    /// Reports a vertical pan from either a trackpad/wheel scroll or a mouse
    /// drag. One gesture covers both directions so the two never contend for
    /// recognition.
    func notchPan(action: @escaping (NotchPan) -> Void) -> some View {
        modifier(NotchPanModifier(action: action))
    }
}

private struct NotchPanModifier: ViewModifier {
    /// Slack before a drag commits to a direction, so a click never reads as a pan.
    static let hysteresis: CGFloat = 10

    let action: (NotchPan) -> Void

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: Self.hysteresis)
                    .onChanged { value in
                        action(NotchPan(
                            translation: value.translation.height,
                            velocity: value.velocity.height,
                            phase: .changed
                        ))
                    }
                    .onEnded { value in
                        action(NotchPan(
                            translation: value.translation.height,
                            velocity: value.velocity.height,
                            phase: .ended
                        ))
                    }
            )
            .background(ScrollPanMonitor(action: action))
    }
}

/// Turns the window's scroll events into a `NotchPan` stream. A trackpad swipe
/// never reaches SwiftUI as a drag, so it has to be read off `NSEvent`.
private struct ScrollPanMonitor: NSViewRepresentable {
    let action: (NotchPan) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    @MainActor
    final class Coordinator: NSObject {
        /// Wheel notches are coarse next to a trackpad; scale them to match.
        private static let wheelScale: CGFloat = 8
        /// Below this a delta is tremor, not a pan.
        private static let noise: CGFloat = 0.2
        /// A momentum-free trackpad swipe never posts an `.ended` phase.
        private static let idleTimeout = Duration.milliseconds(200)

        var action: (NotchPan) -> Void

        private var monitor: Any?
        private var travel: CGFloat = 0
        private var velocity: CGFloat = 0
        private var lastTimestamp: TimeInterval = 0
        private var idleTask: Task<Void, Never>?

        init(action: @escaping (NotchPan) -> Void) {
            self.action = action
        }

        func install(on view: NSView) {
            remove()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === view?.window else { return event }
                    self.handle(event)
                    return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            reset()
        }

        private func handle(_ event: NSEvent) {
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                finish()
                return
            }

            // Anything mostly sideways belongs to the horizontal clip strip.
            guard abs(event.scrollingDeltaY) >= 1.5 * abs(event.scrollingDeltaX) else { return }

            let scale = event.hasPreciseScrollingDeltas ? 1 : Self.wheelScale
            let step = event.scrollingDeltaY * scale
            guard abs(step) > Self.noise else { return }

            let interval = lastTimestamp > 0
                ? max(event.timestamp - lastTimestamp, 1.0 / 240)
                : 1.0 / 60
            lastTimestamp = event.timestamp
            velocity = step / CGFloat(interval)
            travel += step

            action(NotchPan(translation: travel, velocity: velocity, phase: .changed))
            scheduleIdleEnd()
        }

        private func scheduleIdleEnd() {
            idleTask?.cancel()
            idleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.idleTimeout)
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        }

        private func finish() {
            let travelled = travel
            let released = velocity
            reset()
            guard travelled != 0 else { return }
            action(NotchPan(translation: travelled, velocity: released, phase: .ended))
        }

        private func reset() {
            idleTask?.cancel()
            idleTask = nil
            travel = 0
            velocity = 0
            lastTimestamp = 0
        }
    }
}
