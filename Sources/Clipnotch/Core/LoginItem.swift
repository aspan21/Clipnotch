import Combine
import ServiceManagement

/// "Open at login", backed by `SMAppService`. The system owns the truth — the
/// user can flip it in System Settings → Login Items at any time — so nothing
/// is cached in UserDefaults; the status is re-read whenever it is shown.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var isEnabled = false
    /// Registered, but the user still has to allow it in System Settings.
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?

    private init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Most often: running outside an app bundle (`swift run`).
            Log.notch.error("login item: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
