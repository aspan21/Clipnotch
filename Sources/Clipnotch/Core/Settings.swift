import Combine
import Foundation

/// UserDefaults-backed settings. Small enough that a hand-rolled wrapper beats a dependency.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let store = UserDefaults.standard

    private enum Key {
        static let retentionItems = "retentionItems"
        static let retentionDays = "retentionDays"
        static let skipConcealed = "skipConcealed"
        static let showOverFullscreen = "showOverFullscreen"
        static let notchHeightOverride = "notchHeightOverride"
        static let openOnHover = "openOnHover"
        static let advanceDelayMs = "advanceDelayMs"
        static let hasSeenAccessibilityPrompt = "hasSeenAccessibilityPrompt"
        static let focusMinutes = "pomodoroFocusMinutes"
        static let shortBreakMinutes = "pomodoroShortBreakMinutes"
        static let longBreakMinutes = "pomodoroLongBreakMinutes"
    }

    private init() {
        store.register(defaults: [
            Key.retentionItems: 200,
            Key.retentionDays: 7,
            Key.skipConcealed: true,
            Key.showOverFullscreen: true,
            Key.notchHeightOverride: 0,
            Key.openOnHover: true,
            Key.advanceDelayMs: 150,
            Key.focusMinutes: 25,
            Key.shortBreakMinutes: 5,
            Key.longBreakMinutes: 15,
        ])
    }

    /// Hard cap on stored clips. Oldest beyond this are deleted from disk.
    @Published var retentionItems: Int = 0 { didSet { store.set(retentionItems, forKey: Key.retentionItems) } }
    /// Clips older than this many days are deleted from disk. 0 disables age-based purge.
    @Published var retentionDays: Int = 0 { didSet { store.set(retentionDays, forKey: Key.retentionDays) } }
    /// Honour the org.nspasteboard.ConcealedType convention used by password managers.
    @Published var skipConcealed: Bool = true { didSet { store.set(skipConcealed, forKey: Key.skipConcealed) } }
    @Published var showOverFullscreen: Bool = true { didSet { store.set(showOverFullscreen, forKey: Key.showOverFullscreen) } }
    /// 0 means "derive from the display".
    @Published var notchHeightOverride: Double = 0 { didSet { store.set(notchHeightOverride, forKey: Key.notchHeightOverride) } }
    @Published var openOnHover: Bool = true { didSet { store.set(openOnHover, forKey: Key.openOnHover) } }
    /// Delay between the intercepted paste and swapping in the next queue item.
    @Published var advanceDelayMs: Int = 150 { didSet { store.set(advanceDelayMs, forKey: Key.advanceDelayMs) } }

    /// Pomodoro phase lengths, set by dragging round the dial.
    @Published var focusMinutes: Int = 25 { didSet { store.set(focusMinutes, forKey: Key.focusMinutes) } }
    @Published var shortBreakMinutes: Int = 5 { didSet { store.set(shortBreakMinutes, forKey: Key.shortBreakMinutes) } }
    @Published var longBreakMinutes: Int = 15 { didSet { store.set(longBreakMinutes, forKey: Key.longBreakMinutes) } }

    var hasSeenAccessibilityPrompt: Bool {
        get { store.bool(forKey: Key.hasSeenAccessibilityPrompt) }
        set { store.set(newValue, forKey: Key.hasSeenAccessibilityPrompt) }
    }

    func load() {
        retentionItems = store.integer(forKey: Key.retentionItems)
        retentionDays = store.integer(forKey: Key.retentionDays)
        skipConcealed = store.bool(forKey: Key.skipConcealed)
        showOverFullscreen = store.bool(forKey: Key.showOverFullscreen)
        notchHeightOverride = store.double(forKey: Key.notchHeightOverride)
        openOnHover = store.bool(forKey: Key.openOnHover)
        advanceDelayMs = store.integer(forKey: Key.advanceDelayMs)
        focusMinutes = store.integer(forKey: Key.focusMinutes)
        shortBreakMinutes = store.integer(forKey: Key.shortBreakMinutes)
        longBreakMinutes = store.integer(forKey: Key.longBreakMinutes)
    }
}
