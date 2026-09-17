import AppKit
import Carbon.HIToolbox
import Foundation

struct ShortcutModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    static let supported: Self = [.control, .option, .shift, .command]
    static let primary: Self = [.control, .option, .command]

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: Self = []
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }

    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    var displayName: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }
}

struct Shortcut: Equatable, Sendable {
    static let defaultLookup = Shortcut(
        keyCode: UInt16(kVK_ANSI_D),
        modifiers: [.control, .option, .command]
    )

    let keyCode: UInt16
    let modifiers: ShortcutModifiers

    var displayName: String {
        modifiers.displayName + Self.keyDisplayName(for: keyCode)
    }

    func validate() throws {
        guard keyCode <= 127 else {
            throw ShortcutValidationError.unsupportedKey
        }
        guard !Self.modifierKeyCodes.contains(keyCode) else {
            throw ShortcutValidationError.modifierOnly
        }
        guard modifiers.subtracting(.supported).isEmpty else {
            throw ShortcutValidationError.unsupportedModifiers
        }
        guard !modifiers.intersection(.primary).isEmpty else {
            throw ShortcutValidationError.missingPrimaryModifier
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),
        UInt16(kVK_Shift),
        UInt16(kVK_CapsLock),
        UInt16(kVK_Option),
        UInt16(kVK_Control),
        UInt16(kVK_RightCommand),
        UInt16(kVK_RightShift),
        UInt16(kVK_RightOption),
        UInt16(kVK_RightControl),
        UInt16(kVK_Function),
    ]

    private static func keyDisplayName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[keyCode] {
            return special
        }
        return printableKeyName(for: keyCode) ?? "Key \(keyCode)"
    }

    private static func printableKeyName(for keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyUnicodeKeyLayoutData
              ) else {
            return ansiKeyNames[keyCode]
        }

        let layoutData = unsafeBitCast(rawLayout, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return ansiKeyNames[keyCode]
        }

        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 },
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &actualLength,
            &characters
        )
        guard status == noErr, actualLength > 0 else {
            return ansiKeyNames[keyCode]
        }
        return String(utf16CodeUnits: characters, count: actualLength).uppercased()
    }

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Return): "↩",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_F1): "F1",
        UInt16(kVK_F2): "F2",
        UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7",
        UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11",
        UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13",
        UInt16(kVK_F14): "F14",
        UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17",
        UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19",
        UInt16(kVK_F20): "F20",
    ]

    private static let ansiKeyNames: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B",
        UInt16(kVK_ANSI_C): "C", UInt16(kVK_ANSI_D): "D",
        UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H",
        UInt16(kVK_ANSI_I): "I", UInt16(kVK_ANSI_J): "J",
        UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N",
        UInt16(kVK_ANSI_O): "O", UInt16(kVK_ANSI_P): "P",
        UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T",
        UInt16(kVK_ANSI_U): "U", UInt16(kVK_ANSI_V): "V",
        UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1",
        UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7",
        UInt16(kVK_ANSI_8): "8", UInt16(kVK_ANSI_9): "9",
    ]
}

enum ShortcutValidationError: Error, Equatable, LocalizedError {
    case modifierOnly
    case missingPrimaryModifier
    case unsupportedKey
    case unsupportedModifiers

    var errorDescription: String? {
        switch self {
        case .modifierOnly:
            "Press a non-modifier key as part of the shortcut."
        case .missingPrimaryModifier:
            "Use Command, Option, or Control with the key."
        case .unsupportedKey:
            "That key cannot be used as a global shortcut."
        case .unsupportedModifiers:
            "That modifier combination is not supported."
        }
    }
}
