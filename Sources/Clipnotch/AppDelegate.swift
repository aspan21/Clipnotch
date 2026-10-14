import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.load()
        ClipStore.shared.load()
        // Before anything that polls: they all pause through it.
        ScreenActivity.shared.start()

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
        ShortcutCenter.shared.start()

        AgentRadar.shared.start()
        ClaudeHooks.refreshHelperIfInstalled()
    }

    func applicationWillTerminate(_ notification: Notification) {
        PasteQueue.shared.cancel()
        ClipboardMonitor.shared.stop()
        NowPlayingModel.shared.stop()
        AccessibilityGuard.shared.stopMonitoring()
        FullscreenDetector.shared.stop()
        MenuBarObstruction.shared.stop()
        NotchManager.shared.stop()
        ShortcutCenter.shared.stop()
        AgentRadar.shared.stop()
        ScreenActivity.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
