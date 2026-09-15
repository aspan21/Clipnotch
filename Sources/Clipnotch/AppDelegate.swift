import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.load()
        ClipStore.shared.load()

        AccessibilityGuard.shared.startMonitoring()
        NowPlayingModel.shared.start()

        ClipboardMonitor.shared.onExternalCopy = {
            PasteQueue.shared.cancelDueToExternalCopy()
        }
        ClipboardMonitor.shared.start()

        FullscreenDetector.shared.start()
        MenuBarObstruction.shared.start()
        NotchManager.shared.start()
        menuBar.install()
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        PasteQueue.shared.cancel()
        ClipboardMonitor.shared.stop()
        NowPlayingModel.shared.stop()
        AccessibilityGuard.shared.stopMonitoring()
        FullscreenDetector.shared.stop()
        MenuBarObstruction.shared.stop()
        NotchManager.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Hotkey

    private func registerHotKey() {
        hotKey = HotKey(
            keyCode: KeyCode.v,
            modifiers: HotKeyModifiers.command | HotKeyModifiers.shift
        ) {
            Task { @MainActor in
                NotchManager.shared.focused?.toggle(tab: .clipboard)
            }
        }
        if hotKey == nil {
            Log.notch.warning("could not register the global hotkey; another app likely owns it")
        }
    }
}
