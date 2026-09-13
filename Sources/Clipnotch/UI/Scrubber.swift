import SwiftUI

/// Progress bar that grows on hover and seeks on drag.
struct Scrubber: View {
    let value: Double
    let total: Double
    let tint: Color
    let onScrubBegan: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: isHovering || isDragging ? 6 : 3.5)
                .frame(maxHeight: .infinity, alignment: .center)
                .animation(isDragging ? nil : .linear(duration: 0.5), value: fraction)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard total > 0 else { return }
                            if !isDragging {
                                isDragging = true
                                onScrubBegan()
                            }
                            onScrubChanged(seconds(at: drag.location.x, width: geo.size.width))
                        }
                        .onEnded { drag in
                            guard total > 0 else { return }
                            isDragging = false
                            onScrubEnded(seconds(at: drag.location.x, width: geo.size.width))
                        }
                )
            }
            .frame(height: 10)
            .animation(Theme.quick, value: isHovering)
            .onHover { isHovering = $0 }

            HStack {
                Text(Self.timeString(value))
                Spacer()
                Text(Self.timeString(total))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.tertiaryText)
            .monospacedDigit()
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(total, max(0, Double(x / width) * total))
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
