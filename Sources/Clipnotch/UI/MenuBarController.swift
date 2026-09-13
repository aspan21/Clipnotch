import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.on.square.dashed",
            accessibilityDescription: "Clipnotch"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let queue = PasteQueue.shared
        if queue.isActive {
            menu.addItem(withTitle: "Queue: \(queue.queue.count) waiting", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Clear queue", action: #selector(clearQueue), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Open Clipboard  \u{2318}\u{21E7}V", action: #selector(openClipboard), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open Now Playing", action: #selector(openNowPlaying), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        let count = ClipStore.shared.items.count
        menu.addItem(withTitle: "\(count) clip\(count == 1 ? "" : "s") stored", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Clear history", action: #selector(clearHistory), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        if !AccessibilityGuard.shared.isTrusted {
            menu.addItem(withTitle: "Grant Accessibility access…", action: #selector(grantAccess), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Quit Clipnotch", action: #selector(quit), keyEquivalent: "q")
            .target = self
    }

    @objc private func openClipboard() { NotchManager.shared.focused?.open(tab: .clipboard) }
    @objc private func openNowPlaying() { NotchManager.shared.focused?.open(tab: .nowPlaying) }
    @objc private func clearQueue() { PasteQueue.shared.cancel() }
    @objc private func clearHistory() { ClipStore.shared.deleteAll() }
    @objc private func grantAccess() { AccessibilityGuard.shared.requestAccess() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
