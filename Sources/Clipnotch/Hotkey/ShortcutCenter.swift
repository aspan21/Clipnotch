import AppKit
import Carbon.HIToolbox
import Combine

/// Everything a global shortcut can do.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case clipboard
    case nowPlaying
    case shelf
    case pomodoro
    case pomodoroStartPause

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return NotchTab.clipboard.title
        case .nowPlaying: return NotchTab.nowPlaying.title
        case .shelf: return NotchTab.shelf.title
        case .pomodoro: return NotchTab.pomodoro.title
        case .pomodoroStartPause: return String(localized: "Start or Pause Pomodoro")
        }
    }

    /// Only the clipboard ships with a shortcut; the rest are opt-in, so a new
    /// version never grabs a combination another app was using.
    var defaultShortcut: Shortcut? {
        switch self {
        case .clipboard:
            return Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        default:
            return nil
        }
    }

    @MainActor
    func perform() {
        switch self {
        case .clipboard: NotchManager.shared.focused?.toggle(tab: .clipboard)
        case .nowPlaying: NotchManager.shared.focused?.toggle(tab: .nowPlaying)
        case .shelf: NotchManager.shared.focused?.toggle(tab: .shelf)
        case .pomodoro: NotchManager.shared.focused?.toggle(tab: .pomodoro)
        case .pomodoroStartPause:
            // Pauses whatever is running, wherever the pane happens to be;
            // with nothing running, starts the phase the pane shows.
            let timer = PomodoroTimer.shared
            timer.runningPhase != nil ? timer.pause() : timer.start()
        }
    }
}

/// Owns the user's shortcuts: stores them, registers them system-wide, and
/// records new ones for the settings window.
@MainActor
final class ShortcutCenter: ObservableObject {
    static let shared = ShortcutCenter()

    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    /// Actions whose shortcut could not be registered — another app owns it.
    @Published private(set) var unavailable: Set<ShortcutAction> = []
    /// The action whose recorder is waiting for a key press.
    @Published private(set) var recording: ShortcutAction?

    private var hotKeys: [ShortcutAction: HotKey] = [:]
    private var recordMonitor: Any?
    private let store = UserDefaults.standard

    private init() {}

    func start() {
        for action in ShortcutAction.allCases {
            switch store.string(forKey: Self.key(for: action)) {
            case nil: shortcuts[action] = action.defaultShortcut
            case let stored?: shortcuts[action] = Shortcut(storageValue: stored)
            }
        }
        registerAll()
    }

    func stop() {
        endRecording()
        hotKeys.removeAll()
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        shortcuts[action]
    }

    /// Assigns `shortcut` to `action`, or clears it when nil. A combination
    /// belongs to one action: whichever had it before loses it.
    func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if let shortcut {
            for (other, existing) in shortcuts where other != action && existing == shortcut {
                shortcuts[other] = nil
                save(other)
            }
        }
        shortcuts[action] = shortcut
        save(action)
        registerAll()
    }

    // MARK: - Recording

    /// Starts listening for the next key press in this app. All shortcuts are
    /// released meanwhile, otherwise pressing the current one would fire it
    /// instead of recording it.
    func beginRecording(_ action: ShortcutAction) {
        endRecording()
        recording = action
        hotKeys.removeAll()
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                self?.record(keyCode: keyCode, flags: flags) ?? false
            }
            return consumed ? nil : event
        }
    }

    func endRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        guard recording != nil else { return }
        recording = nil
        registerAll()
    }

    /// Esc cancels, a bare Delete clears, anything with ⌘, ⌥ or ⌃ is taken.
    /// Returns whether the key press was consumed.
    private func record(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard let action = recording else { return false }
        let bare = flags.intersection([.command, .option, .control, .shift]).isEmpty

        switch Int(keyCode) {
        case kVK_Escape:
            endRecording()
        case kVK_Delete where bare, kVK_ForwardDelete where bare:
            set(nil, for: action)
            endRecording()
        default:
            guard let shortcut = Shortcut(keyCode: keyCode, flags: flags) else {
                NSSound.beep()
                return true
            }
            set(shortcut, for: action)
            endRecording()
        }
        return true
    }

    // MARK: - Internals

    private static func key(for action: ShortcutAction) -> String {
        "shortcut.\(action.rawValue)"
    }

    /// An empty string records "cleared on purpose", which is not the same as
    /// "never touched" — the latter falls back to the default.
    private func save(_ action: ShortcutAction) {
        store.set(shortcuts[action]?.storageValue ?? "", forKey: Self.key(for: action))
    }

    private func registerAll() {
        // Dropping a HotKey unregisters it.
        hotKeys.removeAll()
        guard recording == nil else { return }

        var failed = Set<ShortcutAction>()
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
                Task { @MainActor in action.perform() }
            }
            if let hotKey {
                hotKeys[action] = hotKey
            } else {
                failed.insert(action)
                Log.notch.warning("could not register \(shortcut.displayString, privacy: .public) for \(action.rawValue, privacy: .public); another app likely owns it")
            }
        }
        if failed != unavailable { unavailable = failed }
    }
}
