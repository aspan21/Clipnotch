import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store = ClipStore.shared
    @ObservedObject var access = AccessibilityGuard.shared
    @ObservedObject var loginItem = LoginItem.shared
    @ObservedObject var shortcuts = ShortcutCenter.shared

    @State private var hooksInstalled = ClaudeHooks.isInstalled()
    @State private var hooksPlan: ClaudeHooks.Plan?
    @State private var hooksError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.needsApproval {
                    HStack {
                        Text("Allow Clipnotch in Login Items to finish turning this on.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Hooks") {
                    HStack(spacing: 8) {
                        Text(hooksInstalled ? String(localized: "Installed") : String(localized: "Not Installed"))
                            .foregroundStyle(hooksInstalled ? .green : .secondary)
                        Button(hooksInstalled ? String(localized: "Remove…") : String(localized: "Install…")) {
                            reviewHooks(install: !hooksInstalled)
                        }
                    }
                }
                Toggle("Play a sound when a session needs you", isOn: $settings.agentSound)
                if let hooksError {
                    Text(hooksError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("The notch lights up when a session finishes its turn, asks for permission or asks a question. The hooks only report; they never answer for you. New sessions pick them up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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
                Text("On displays without a notch, double-click the strip or hold the pointer against the top edge for 3 seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Show over full-screen apps (requires restart)", isOn: $settings.showOverFullscreen)
                Stepper(value: $settings.notchHeightOverride, in: 0...48, step: 1) {
                    LabeledContent("Custom Height",
                                   value: settings.notchHeightOverride == 0
                                       ? String(localized: "Automatic")
                                       : String(localized: "\(Int(settings.notchHeightOverride)) pt"))
                }
            }

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action)
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Work from any app. Each needs \u{2318}, \u{2325} or \u{2303}. While recording, Esc cancels and Delete clears.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
        .frame(width: 460, height: 700)
        .onChange(of: settings.retentionItems) { _, _ in store.purge() }
        .onChange(of: settings.retentionDays) { _, _ in store.purge() }
        // The switch may have been flipped in System Settings since last time.
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        // Key presses only reach the recorder while this app is in front; a
        // recorder left waiting would keep every shortcut released.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            shortcuts.endRecording()
        }
        .onDisappear { shortcuts.endRecording() }
        .sheet(isPresented: Binding(get: { hooksPlan != nil }, set: { if !$0 { hooksPlan = nil } })) {
            if let plan = hooksPlan {
                HooksReviewSheet(plan: plan) {
                    applyHooks(plan)
                } cancel: {
                    hooksPlan = nil
                }
            }
        }
    }

    private func reviewHooks(install: Bool) {
        hooksError = nil
        do {
            hooksPlan = try ClaudeHooks.plan(install: install)
        } catch {
            hooksError = error.localizedDescription
        }
    }

    private func applyHooks(_ plan: ClaudeHooks.Plan) {
        hooksPlan = nil
        do {
            try ClaudeHooks.apply(plan)
        } catch {
            hooksError = error.localizedDescription
        }
        hooksInstalled = ClaudeHooks.isInstalled()
    }
}

/// What installing or removing the hooks does to `~/.claude/settings.json`,
/// before anything is written.
private struct HooksReviewSheet: View {
    let plan: ClaudeHooks.Plan
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.install ? "Install Claude Code Hooks" : "Remove Claude Code Hooks")
                .font(.headline)
            Text("Changes to \(ClaudeHooks.settingsURL.path). A backup is saved next to it first. Keys are written in sorted order.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, design: .monospaced))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(plan.install ? "Install" : "Remove", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private func row(_ line: ClaudeHooks.DiffLine) -> some View {
        switch line {
        case .same(let text):
            Text(verbatim: "  " + text).foregroundStyle(.secondary)
        case .added(let text):
            Text(verbatim: "+ " + text)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
        case .removed(let text):
            Text(verbatim: "- " + text)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1))
        case .gap:
            Text(verbatim: "  …").foregroundStyle(.tertiary)
        }
    }
}

/// A shortcut field: click, press the combination.
private struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject var center = ShortcutCenter.shared

    private var isRecording: Bool { center.recording == action }

    var body: some View {
        HStack(spacing: 6) {
            if center.unavailable.contains(action), !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(String(localized: "Another app already uses this shortcut."))
            }

            Button {
                isRecording ? center.endRecording() : center.beginRecording(action)
            } label: {
                Text(label)
                    .foregroundStyle(isRecording || center.shortcut(for: action) == nil ? .secondary : .primary)
                    .frame(minWidth: 96)
            }

            Button {
                center.set(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(String(localized: "Clear Shortcut"))
            // Kept in the layout so the fields stay aligned down the column.
            .opacity(center.shortcut(for: action) == nil || isRecording ? 0 : 1)
            .disabled(center.shortcut(for: action) == nil || isRecording)
        }
    }

    private var label: String {
        if isRecording { return String(localized: "Type Shortcut…") }
        return center.shortcut(for: action)?.displayString ?? String(localized: "Not Set")
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
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
