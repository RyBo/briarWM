import Carbon.HIToolbox

/// A resolved hotkey: a virtual keycode plus a Carbon modifier mask
/// (the masks `RegisterEventHotKey` expects: cmdKey/optionKey/controlKey/shiftKey).
struct KeyCombo: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
}

enum Keycodes {

    /// Carbon modifier mask for a single token, resolving `mod`/`$mod` to `defaultMod`.
    /// Returns nil if the token is not a modifier (i.e. it's the key itself).
    static func modifierMask(for token: String, defaultMod: String) -> UInt32? {
        switch token.lowercased() {
        case "mod", "$mod": return modifierMask(forName: defaultMod)
        case "alt", "option", "opt": return UInt32(optionKey)
        case "cmd", "command", "super", "win", "meta": return UInt32(cmdKey)
        case "ctrl", "control": return UInt32(controlKey)
        case "shift": return UInt32(shiftKey)
        case "hyper": return UInt32(cmdKey | optionKey | controlKey | shiftKey)
        default: return nil
        }
    }

    /// The names `modifierMask(forName:)` maps deliberately — anything else silently
    /// falls back to alt, so config validation flags unknown names against this set.
    static let knownModifierNames: Set<String> = [
        "alt", "option", "opt", "cmd", "command", "super",
        "ctrl", "control", "shift", "hyper",
    ]

    /// Carbon mask for the configured default modifier name (falls back to Alt).
    static func modifierMask(forName name: String) -> UInt32 {
        switch name.lowercased() {
        case "cmd", "command", "super": return UInt32(cmdKey)
        case "ctrl", "control": return UInt32(controlKey)
        case "shift": return UInt32(shiftKey)
        case "hyper": return UInt32(cmdKey | optionKey | controlKey | shiftKey)
        default: return UInt32(optionKey) // alt / option
        }
    }

    /// Virtual keycode for a key name, or nil if unknown.
    static func keyCode(for name: String) -> UInt32? {
        table[name.lowercased()].map { UInt32($0) }
    }

    static let table: [String: Int] = [
        // Letters
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        // Digits
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        // Whitespace / editing
        "return": kVK_Return, "enter": kVK_Return,
        "space": kVK_Space,
        "tab": kVK_Tab,
        "escape": kVK_Escape, "esc": kVK_Escape,
        "delete": kVK_Delete, "backspace": kVK_Delete,
        "forwarddelete": kVK_ForwardDelete,
        // Arrows
        "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow,
        // Punctuation
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
        "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash,
        "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote,
        "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
        "backslash": kVK_ANSI_Backslash, "grave": kVK_ANSI_Grave,
        // Function keys
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
        "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
}

extension KeyCombo {
    /// Parse a binding string like `"alt+shift+h"`. `$mod`/`mod` resolves to `defaultMod`.
    /// Returns nil if there is no valid key token, or more than one — a malformed combo
    /// like `"alt+h+l"` must fail loudly (via the validator) rather than silently bind
    /// only its last key.
    static func parse(_ string: String, defaultMod: String) -> KeyCombo? {
        let tokens = string.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !tokens.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var keyName: String?
        for token in tokens {
            if let mask = Keycodes.modifierMask(for: token, defaultMod: defaultMod) {
                modifiers |= mask
            } else {
                guard keyName == nil else { return nil }
                keyName = token
            }
        }
        guard let name = keyName, let code = Keycodes.keyCode(for: name) else { return nil }
        return KeyCombo(keyCode: code, modifiers: modifiers)
    }
}
