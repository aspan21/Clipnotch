import AppKit
import Carbon.HIToolbox

/// Thin wrapper over Carbon's RegisterEventHotKey. Unlike a CGEvent tap this
/// needs no Accessibility grant, which matters because the panel must be
/// reachable before the user has approved anything.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var reference: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installDispatcherIfNeeded()

        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4E48), id: id) // 'CLNH'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                        GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            Self.handlers.removeValue(forKey: id)
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.handlers.removeValue(forKey: id)
    }

    private static func installDispatcherIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            HotKey.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}

enum KeyCode {
    static let v: UInt32 = 9
}

enum HotKeyModifiers {
    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
}
