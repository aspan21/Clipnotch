import AppKit
import Combine
import CoreGraphics
import Foundation

/// Sequential paste queue.
///
/// Design note: this never synthesises a ⌘V. Instead it *pre-arms* the system
/// pasteboard with the head of the queue and installs a **listen-only** event
/// tap. When the user's own ⌘V goes through, the tap sees it and swaps the next
/// item in afterwards. Consequences:
///
///   * a bug here can never break the user's ⌘V, only leave the wrong clip armed;
///   * no event injection, so no re-entrancy and no fighting the target app;
///   * the paste is the user's real keystroke, so apps that inspect the event
///     source (some Electron editors do) behave normally.
@MainActor
final class PasteQueue: ObservableObject {
    static let shared = PasteQueue()

    @Published private(set) var queue: [ClipItem] = []
    /// Set while a swap is pending so the UI can show the beat.
    @Published private(set) var isAdvancing = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var savedPasteboard: PasteboardWriter.Snapshot?
    private var lastAdvance: Date = .distantPast
    private var advanceWorkItem: DispatchWorkItem?

    /// Ignore repeat ⌘V within this window; guards against key repeat.
    private var minAdvanceInterval: TimeInterval { Double(Settings.shared.advanceDelayMs) / 1000 + 0.05 }

    private init() {}

    var isActive: Bool { !queue.isEmpty }
    var next: ClipItem? { queue.first }

    // MARK: - Queue editing

    func enqueue(_ item: ClipItem) {
        let wasEmpty = queue.isEmpty
        if wasEmpty {
            let snapshot = PasteboardWriter.snapshotCurrent()
            installTap()
            // Without a tap nothing would ever advance the queue, so degrade to
            // a plain copy rather than silently hijacking the pasteboard.
            guard tap != nil else {
                copyWithoutQueue(item)
                return
            }
            savedPasteboard = snapshot
        }
        queue.append(item)
        armHead()
    }

    func toggle(_ item: ClipItem) {
        if let index = queue.firstIndex(where: { $0.id == item.id }) {
            remove(at: index)
        } else {
            enqueue(item)
        }
    }

    func remove(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if queue.isEmpty { finish() } else if index == 0 { armHead() }
    }

    func position(of item: ClipItem) -> Int? {
        queue.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
    }

    /// Drops the queue and puts the user's original clipboard back.
    func cancel() {
        guard isActive || savedPasteboard != nil else { return }
        queue.removeAll()
        finish()
    }

    /// Called when a copy happened outside this app: the user changed their mind.
    func cancelDueToExternalCopy() {
        guard isActive else { return }
        Log.paste.info("queue cancelled: external copy")
        queue.removeAll()
        advanceWorkItem?.cancel()
        savedPasteboard = nil // the new copy is what the user wants now
        removeTap()
        isAdvancing = false
    }

    // MARK: - Pasteboard arming

    private func armHead() {
        guard let head = queue.first, let payload = ClipStore.shared.payload(for: head) else { return }
        let changeCount = PasteboardWriter.write(head, payload: payload)
        ClipboardMonitor.shared.ignore(changeCount: changeCount)
    }

    private func finish() {
        advanceWorkItem?.cancel()
        isAdvancing = false
        if let saved = savedPasteboard {
            let changeCount = PasteboardWriter.restore(saved)
            ClipboardMonitor.shared.ignore(changeCount: changeCount)
            savedPasteboard = nil
        }
        removeTap()
    }

    /// Consumes the head after the user pasted it, then arms the next one.
    private func advance() {
        guard !queue.isEmpty else { return }
        queue.removeFirst()
        if queue.isEmpty {
            finish()
        } else {
            armHead()
            isAdvancing = false
        }
    }

    fileprivate func handlePasteKeystroke() {
        guard isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAdvance) > minAdvanceInterval else { return }
        lastAdvance = now
        isAdvancing = true

        // Let the front app finish reading the pasteboard before swapping it.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.advance() }
        }
        advanceWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Settings.shared.advanceDelayMs),
            execute: work
        )
    }

    // MARK: - Event tap

    private func installTap() {
        guard tap == nil else { return }
        guard AccessibilityGuard.shared.isTrusted else {
            Log.paste.info("event tap skipped: no Accessibility access")
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            // Listen-only taps get disabled if they ever stall; re-enable in place.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { PasteQueue.shared.reenableTap() }
                return nil
            }
            guard type == .keyDown else { return nil }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            // kVK_ANSI_V == 9. Plain ⌘V only: ⌘⇧V and ⌘⌥V are other commands.
            let isCommandV = keyCode == 9
                && flags.contains(.maskCommand)
                && !flags.contains(.maskShift)
                && !flags.contains(.maskAlternate)
                && !flags.contains(.maskControl)

            if isCommandV {
                MainActor.assumeIsolated { PasteQueue.shared.handlePasteKeystroke() }
            }
            return nil
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            Log.paste.error("failed to create event tap")
            return
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.paste.info("event tap installed")
    }

    fileprivate func reenableTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
        Log.paste.info("event tap removed")
    }

    /// Fallback for when Accessibility is not granted: just copy the item.
    func copyWithoutQueue(_ item: ClipItem) {
        guard let payload = ClipStore.shared.payload(for: item) else { return }
        let changeCount = PasteboardWriter.write(item, payload: payload)
        ClipboardMonitor.shared.ignore(changeCount: changeCount)
    }
}
