import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store = ClipStore.shared
    @ObservedObject var access = AccessibilityGuard.shared

    /// Russian plurals take three forms, so the count decides the word.
    private static func dayWord(_ count: Int) -> String {
        plural(count, one: "день", few: "дня", many: "дней")
    }

    private static func clipWord(_ count: Int) -> String {
        plural(count, one: "клип", few: "клипа", many: "клипов")
    }

    private static func plural(_ count: Int, one: String, few: String, many: String) -> String {
        let mod100 = count % 100
        if (11...14).contains(mod100) { return many }
        switch count % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    var body: some View {
        Form {
            Section("История") {
                Stepper(value: $settings.retentionItems, in: 10...2000, step: 10) {
                    LabeledContent("Хранить не более", value: "\(settings.retentionItems) \(Self.clipWord(settings.retentionItems))")
                }
                Stepper(value: $settings.retentionDays, in: 0...90) {
                    LabeledContent("Удалять через",
                                   value: settings.retentionDays == 0
                                       ? "никогда"
                                       : "\(settings.retentionDays) \(Self.dayWord(settings.retentionDays))")
                }
                Toggle("Пропускать содержимое, помеченное менеджерами паролей как приватное", isOn: $settings.skipConcealed)

                LabeledContent("Сейчас хранится") {
                    Text("\(store.items.count) \(Self.clipWord(store.items.count)) · \(ByteCountFormatter.string(fromByteCount: store.diskUsage, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Очистить историю") { store.deleteAll() }
                    Button("Показать в Finder") { store.revealInFinder() }
                    Spacer()
                }
            }

            Section("Панель") {
                Toggle("Открывать при наведении", isOn: $settings.openOnHover)
                Toggle("Показывать поверх полноэкранных приложений (нужен перезапуск)", isOn: $settings.showOverFullscreen)
                Stepper(value: $settings.notchHeightOverride, in: 0...48, step: 1) {
                    LabeledContent("Своя высота",
                                   value: settings.notchHeightOverride == 0
                                       ? "авто"
                                       : "\(Int(settings.notchHeightOverride)) pt")
                }
            }

            Section("Очередь вставки") {
                LabeledContent("Доступ к Универсальному доступу") {
                    HStack(spacing: 8) {
                        Text(access.isTrusted ? "Выдан" : "Не выдан")
                            .foregroundStyle(access.isTrusted ? .green : .orange)
                        if !access.isTrusted {
                            Button("Открыть настройки") { access.openSystemSettings() }
                        }
                    }
                }
                Stepper(value: $settings.advanceDelayMs, in: 50...600, step: 25) {
                    LabeledContent("Задержка подмены после \u{2318}V", value: "\(settings.advanceDelayMs) мс")
                }
                Text("Увеличьте задержку, если приложение иногда вставляет предыдущий клип.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 540)
        .onChange(of: settings.retentionItems) { _, _ in store.purge() }
        .onChange(of: settings.retentionDays) { _, _ in store.purge() }
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Clipnotch"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
