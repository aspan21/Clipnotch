import AppKit
import Combine

/// Whether anyone can see the screen. Pollers stop while the displays sleep,
/// the screen is locked, or another user's session is in front: nothing they
/// produce can be seen, and every wake-up costs battery.
@MainActor
final class ScreenActivity: ObservableObject {
    static let shared = ScreenActivity()

    @Published private(set) var isActive = true

    private var displaysAsleep = false { didSet { update() } }
    private var locked = false { didSet { update() } }
    private var sessionInactive = false { didSet { update() } }

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        // No public API reports the lock screen; these are what the system
        // broadcasts, and what every menu bar utility listens to.
        let distributed = DistributedNotificationCenter.default()

        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
    }

    func stop() {
        cancellables.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ apply: @escaping (ScreenActivity) -> Void) {
        center.publisher(for: name)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                }
            }
            .store(in: &cancellables)
    }

    private func update() {
        let active = !displaysAsleep && !locked && !sessionInactive
        guard active != isActive else { return }
        isActive = active
        Log.notch.info("screen \(active ? "active" : "inactive", privacy: .public); pollers \(active ? "resumed" : "paused", privacy: .public)")
    }
}
