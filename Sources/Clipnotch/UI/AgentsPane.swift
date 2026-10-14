import SwiftUI

/// Claude Code sessions, the ones waiting on you first. Clicking one brings
/// its terminal forward.
struct AgentsPane: View {
    @ObservedObject var radar = AgentRadar.shared
    @EnvironmentObject var controller: NotchController

    /// Read once per appearance: it is a file read, and installing happens in
    /// the settings window anyway.
    @State private var hooksInstalled = true

    var body: some View {
        Group {
            if !hooksInstalled {
                placeholder(
                    title: String(localized: "Claude Code Isn’t Connected"),
                    message: String(localized: "Install the hooks in Settings to see when a session finishes or needs you."),
                    showsSettings: true
                )
            } else if radar.sessions.isEmpty {
                placeholder(
                    title: String(localized: "No Claude Code Sessions"),
                    message: String(localized: "A session shows up here once it starts working."),
                    showsSettings: false
                )
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { hooksInstalled = ClaudeHooks.isInstalled() }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(radar.sessions) { session in
                    AgentRow(session: session) {
                        radar.open(session)
                        controller.close()
                    } dismiss: {
                        radar.acknowledge(session.id)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 2)
        }
        .animation(Theme.snap, value: radar.sessions)
    }

    private func placeholder(title: String, message: String, showsSettings: Bool) -> some View {
        VStack(spacing: 7) {
            Image(systemName: NotchTab.agents.symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(Theme.tracking(forSize: 13))
                .foregroundStyle(Theme.secondaryText)
            Text(message)
                .font(.system(size: 11))
                .tracking(Theme.tracking(forSize: 11))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
            if showsSettings {
                Button("Open Settings") {
                    controller.close()
                    SettingsWindowController.shared.show()
                }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: 360)
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let open: () -> Void
    let dismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: session.state.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.state.tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: session.needsAttention)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(session.state.tint.opacity(0.14)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(Theme.tracking(forSize: 12))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .tracking(Theme.tracking(forSize: 10.5))
                        .foregroundStyle(session.state.needsYou ? session.state.tint.opacity(0.9) : Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.elapsed(since: session.since, now: context.date))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tertiaryText)
                }

                if session.needsAttention {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.cardFill))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Mark as Seen"))
                    .opacity(isHovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Theme.cardFillHover : Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(session.needsAttention ? session.state.tint.opacity(0.35) : Theme.cardStroke)
            )
            // Seen, but still waiting: kept in the list, out of the way.
            .opacity(session.state.needsYou && !session.needsAttention ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.quick, value: isHovering)
        .onHover { isHovering = $0 }
        .help(String(localized: "Open the terminal"))
    }

    private var subtitle: String {
        guard let detail = session.detail, !detail.isEmpty else { return session.state.title }
        return session.state.title + " · " + detail
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 1
        return formatter
    }()

    private static func elapsed(since: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(since)
        guard interval >= 60 else { return String(localized: "now") }
        return formatter.string(from: interval) ?? ""
    }
}
