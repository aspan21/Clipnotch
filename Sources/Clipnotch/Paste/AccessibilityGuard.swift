import ApplicationServices
import AppKit
import Combine

/// Tracks the Accessibility (AXIsProcessTrusted) grant that the ⌘V event tap needs.
@MainActor
final class AccessibilityGuard: ObservableObject {
    static let shared = AccessibilityGuard()

    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var timer: Timer?

    private init() {}

    func startMonitoring() {
        refresh()
        // No notification exists for a TCC grant, so poll while untrusted.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
    }

    /// Shows the system prompt. Only useful once per app signature.
    func requestAccess() {
        Settings.shared.hasSeenAccessibilityPrompt = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
