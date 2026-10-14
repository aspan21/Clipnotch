import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifier flags — the form `RegisterEventHotKey` takes.
struct Shortcut: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    private static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
    /// At least one of these is required. A global shortcut on a bare key, or
    /// on shift alone, would swallow ordinary typing in every app.
    private static let requiredMask = UInt32(cmdKey | optionKey | controlKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// The shortcut a key press in the recorder describes, or nil if it has no
    /// ⌘, ⌥ or ⌃.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        guard modifiers & Self.requiredMask != 0 else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    // MARK: - Storage

    /// `keyCode:modifiers`, both decimal.
    var storageValue: String { "\(keyCode):\(modifiers)" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt32(parts[0]),
              let modifiers = UInt32(parts[1])
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - Display

    /// Menu-style label, modifiers in the system's order: ⌃⌥⇧⌘.
    var displayString: String {
        var label = ""
        if modifiers & UInt32(controlKey) != 0 { label += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { label += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { label += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { label += "\u{2318}" }
        return label + Self.keyName(for: keyCode)
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "\u{21A9}", kVK_Tab: "\u{21E5}", kVK_Space: String(localized: "Space"),
        kVK_Delete: "\u{232B}", kVK_ForwardDelete: "\u{2326}", kVK_Escape: "\u{238B}",
        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
        kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
        kVK_Home: "\u{2196}", kVK_End: "\u{2198}",
        kVK_PageUp: "\u{21DE}", kVK_PageDown: "\u{21DF}",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        if let name = specialKeyNames[Int(keyCode)] { return name }
        return character(for: keyCode) ?? "#\(keyCode)"
    }

    /// The character the key types on an ASCII-capable layout. Key codes are
    /// positions, not letters, and the active layout may be Cyrillic — where
    /// ⌘⇧V would otherwise read as ⌘⇧М.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text.uppercased()
        }
    }
}
