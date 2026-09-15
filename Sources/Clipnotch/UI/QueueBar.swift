import SwiftUI

/// Strip above the clipboard grid: what is armed, what comes next, how to bail.
struct QueueBar: View {
    @ObservedObject var queue = PasteQueue.shared
    @ObservedObject var access = AccessibilityGuard.shared

    var body: some View {
        HStack(spacing: 10) {
            if !access.isTrusted {
                permissionNotice
            } else if queue.isActive {
                activeQueue
            } else {
                hint
            }
        }
        .frame(height: 26)
        .animation(Theme.snap, value: queue.queue.count)
    }

    private var activeQueue: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.number")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)

            HStack(spacing: 3) {
                ForEach(Array(queue.queue.enumerated()), id: \.element.id) { index, item in
                    Text("\(index + 1)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(index == 0 ? .black : Theme.accent)
                        .frame(width: 17, height: 17)
                        .background(
                            Circle().fill(index == 0 ? Theme.accent : Theme.accent.opacity(0.18))
                        )
                        .help(item.subtitle)
                }
            }

            Text(queue.queue.count == 1
                 ? String(localized: "Press \u{2318}V to paste")
                 : String(localized: "Press \u{2318}V \(queue.queue.count) times to paste in order"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondaryText)

            Spacer()

            Button("Clear") { queue.cancel() }
                .buttonStyle(PillButtonStyle())
        }
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Text("Click clips in order, then paste them with \u{2318}V")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Paste in order requires Accessibility access. Until then, clicking a clip copies it.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer()
            Button("Allow") {
                // The prompt only appears once per signature, so a second press
                // has to reach the Settings pane instead. Ask either way: the
                // "already asked" flag can go stale — a `tccutil reset` makes
                // the prompt available again — and asking when macOS will not
                // show it does nothing.
                let alreadyAsked = Settings.shared.hasSeenAccessibilityPrompt
                access.requestAccess()
                if alreadyAsked { access.openSystemSettings() }
            }
            .buttonStyle(PillButtonStyle(tint: .orange))
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.3 : 0.16)))
    }
}
