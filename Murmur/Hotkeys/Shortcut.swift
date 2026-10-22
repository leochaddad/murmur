import AppKit
import Carbon.HIToolbox

/// A global trigger: either a key combination such as ⌃⇧Space (registered with Carbon's
/// `RegisterEventHotKey`, no permission needed) or a single modifier key such as Fn or
/// Right ⌥ (observed with an event monitor, requires Accessibility).
struct Shortcut: Codable, Hashable {
    var keyCode: UInt16
    /// Device-independent `NSEvent.ModifierFlags` raw value. Empty for modifier-only shortcuts.
    var modifierFlags: UInt
    var isModifierOnly: Bool

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.intersection(Self.relevantModifiers).rawValue
        self.isModifierOnly = false
    }

    static func modifierKey(_ keyCode: UInt16) -> Shortcut {
        var shortcut = Shortcut(keyCode: keyCode, modifiers: [])
        shortcut.isModifierOnly = true
        return shortcut
    }

    /// ⌃⇧Space. Not used by macOS, and — unlike ⌥Space — still allowed on macOS 15,
    /// which rejects hot keys whose only modifiers are ⌥ or ⌥⇧.
    static let defaultDictation = Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .shift])

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(Self.relevantModifiers)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// A quick tap on Fn 🌐 is how macOS opens the emoji picker (or switches input source), so
    /// taps are left to the system and only holds dictate.
    var tapBelongsToSystem: Bool {
        isModifierOnly && keyCode == UInt16(kVK_Function)
    }

    // MARK: Validation

    /// Keys that may be used on their own as a push-to-talk / toggle trigger.
    static let supportedModifierKeys: [UInt16] = [
        UInt16(kVK_Function), UInt16(kVK_RightOption), UInt16(kVK_RightCommand),
        UInt16(kVK_RightControl), UInt16(kVK_RightShift),
    ]

    static let functionKeyCodes: Set<UInt16> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map { UInt16($0) })

    /// Returns a user-facing reason if this combination can't be used as a global shortcut.
    var validationError: String? {
        if isModifierOnly {
            return Self.supportedModifierKeys.contains(keyCode) ? nil : "Use Fn or a right-hand modifier key on its own."
        }
        let mods = modifiers
        if mods.isEmpty && !Self.functionKeyCodes.contains(keyCode) {
            return "Add ⌘, ⌃ or ⌥ — a single key would get in the way of typing."
        }
        if !mods.isEmpty && mods.isSubset(of: [.option, .shift]) {
            return "macOS doesn’t allow global shortcuts that use only ⌥ or ⌥⇧. Add ⌃ or ⌘."
        }
        return nil
    }

    // MARK: Display

    var displayString: String {
        if isModifierOnly { return Self.modifierKeyName(keyCode) }
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.keyName(keyCode)
    }

    /// Key equivalent for showing the shortcut next to an NSMenuItem (display only).
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard !isModifierOnly else { return nil }
        let key: String
        switch Int(keyCode) {
        case kVK_Space: key = " "
        case kVK_Return: key = "\r"
        case kVK_Tab: key = "\t"
        case kVK_Escape: key = "\u{1B}"
        default:
            if let special = Self.specialKeyNames[Int(keyCode)], special.count == 1 {
                key = special
            } else if let character = KeyboardLayout.character(for: keyCode), character.count == 1 {
                key = character.lowercased()
            } else {
                return nil
            }
        }
        return (key, modifiers)
    }

    static func modifierKeyName(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Function: return "Fn 🌐"
        case kVK_RightOption: return "Right ⌥"
        case kVK_RightCommand: return "Right ⌘"
        case kVK_RightControl: return "Right ⌃"
        case kVK_RightShift: return "Right ⇧"
        case kVK_Option: return "Left ⌥"
        case kVK_Command: return "Left ⌘"
        case kVK_Control: return "Left ⌃"
        case kVK_Shift: return "Left ⇧"
        default: return "Key \(keyCode)"
        }
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Help",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func keyName(_ keyCode: UInt16) -> String {
        if let name = specialKeyNames[Int(keyCode)] { return name }
        return KeyboardLayout.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }
}

/// Translates between virtual key codes and characters using the user's keyboard layout,
/// so shortcuts display correctly and ⌘V is sent with the right key on non-QWERTY layouts.
enum KeyboardLayout {
    static func character(for keyCode: UInt16, modifierKeyState: UInt32 = 0) -> String? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), modifierKeyState, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    /// The key code that produces `character` while ⌘ is held (handles Dvorak, AZERTY, "Dvorak – QWERTY ⌘" …).
    static func keyCode(for character: Character) -> CGKeyCode? {
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let target = String(character).lowercased()
        for code in UInt16(0)..<128 where Self.character(for: code, modifierKeyState: commandState)?.lowercased() == target {
            return CGKeyCode(code)
        }
        return nil
    }
}
