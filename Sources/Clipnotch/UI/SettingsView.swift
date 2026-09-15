import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store = ClipStore.shared
    @ObservedObject var access = AccessibilityGuard.shared

    var body: some View {
        Form {
            Section("History") {
                Stepper(value: $settings.retentionItems, in: 10...2000, step: 10) {
                    LabeledContent("Keep Up To", value: String(localized: "\(settings.retentionItems) clips"))
                }
                Stepper(value: $settings.retentionDays, in: 0...90) {
                    LabeledContent("Delete After",
                                   value: settings.retentionDays == 0
                                       ? String(localized: "Never")
                                       : String(localized: "\(settings.retentionDays) days"))
                }
                Toggle("Skip items that password managers mark as private", isOn: $settings.skipConcealed)

                LabeledContent("Stored Now") {
                    Text(verbatim: String(localized: "\(store.items.count) clips")
                        + " · "
                        + ByteCountFormatter.string(fromByteCount: store.diskUsage, countStyle: .file))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Clear History") { store.deleteAll() }
                    Button("Show in Finder") { store.revealInFinder() }
                    Spacer()
                }
            }

            Section("Panel") {
                Toggle("Open on hover", isOn: $settings.openOnHover)
                Toggle("Show over full-screen apps (requires restart)", isOn: $settings.showOverFullscreen)
                Stepper(value: $settings.notchHeightOverride, in: 0...48, step: 1) {
                    LabeledContent("Custom Height",
                                   value: settings.notchHeightOverride == 0
                                       ? String(localized: "Automatic")
                                       : String(localized: "\(Int(settings.notchHeightOverride)) pt"))
                }
            }

            Section("Paste Queue") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        Text(access.isTrusted ? String(localized: "Allowed") : String(localized: "Not Allowed"))
                            .foregroundStyle(access.isTrusted ? .green : .orange)
                        if !access.isTrusted {
                            Button("Open Settings") { access.openSystemSettings() }
                        }
                    }
                }
                Stepper(value: $settings.advanceDelayMs, in: 50...600, step: 25) {
                    LabeledContent("Swap Delay After \u{2318}V", value: String(localized: "\(settings.advanceDelayMs) ms"))
                }
                Text("Increase the delay if an app sometimes pastes the previous clip.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 540)
        .onChange(of: settings.retentionItems) { _, _ in store.purge() }
        .onChange(of: settings.retentionDays) { _, _ in store.purge() }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Clipnotch Settings")
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
