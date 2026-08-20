import Foundation

/// The modifier keys a shortcut can hold.
///
/// Our own set rather than `NSEvent.ModifierFlags`, so this file stays free of
/// AppKit and can be tested with no app, and rather than Carbon's constants, so
/// the number written into UserDefaults is ours and cannot change meaning if
/// Carbon ever does. The Mac layer converts in both directions.
public struct ShortcutModifiers: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift   = ShortcutModifiers(rawValue: 1 << 1)
    public static let option  = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

/// A global keyboard shortcut: one key, plus the modifiers held with it.
public struct Shortcut: Equatable, Sendable {
    /// The virtual key code. Position on the keyboard, not the letter printed
    /// on it, which is why `label` is stored beside it: on a Dvorak or an AZERTY
    /// layout the same code prints something else.
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers
    /// What was printed on the key when it was recorded, uppercased.
    public let label: String

    public init(keyCode: UInt32, modifiers: ShortcutModifiers, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// Cmd+Shift+V. 9 is the V key.
    public static let panelDefault = Shortcut(keyCode: 9,
                                              modifiers: [.command, .shift],
                                              label: "V")

    /// Whether this is safe to register as a global shortcut.
    ///
    /// A shortcut with no modifier, or with only Shift, would swallow an
    /// ordinary keystroke everywhere on the Mac: registering plain "V" means
    /// nobody can type the letter V in any app again. The panel would open
    /// while you typed, and the cause would be very hard to guess. So the
    /// recorder refuses these rather than storing them and letting the user
    /// find out.
    public var isUsable: Bool {
        guard !label.isEmpty else { return false }
        return !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// The symbols, in the order macOS shows them everywhere: ⌃⌥⇧⌘ then the key.
    public var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option)  { out += "⌥" }
        if modifiers.contains(.shift)   { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + label
    }

    // MARK: - Storage

    /// One string, not three defaults keys.
    ///
    /// Three keys can be half written: a crash between the second and the third
    /// leaves a shortcut whose code and label disagree, which is a combination
    /// nobody can debug from the outside. One value is either there and whole
    /// or absent, and absent means the default.
    ///
    /// The label is last and is never split, so a key that prints a pipe still
    /// round trips.
    public var encoded: String { "\(keyCode)|\(modifiers.rawValue)|\(label)" }

    public init?(encoded: String) {
        let parts = encoded.split(separator: "|", maxSplits: 2,
                                  omittingEmptySubsequences: false)
        guard parts.count == 3,
              let code = UInt32(parts[0]),
              let bits = UInt32(parts[1]),
              !parts[2].isEmpty else { return nil }
        self.init(keyCode: code, modifiers: ShortcutModifiers(rawValue: bits),
                  label: String(parts[2]))
    }
}

/// The name to print for keys that print nothing.
///
/// A key code carries no text, so a shortcut on Space or F5 would otherwise
/// record an empty label and be rejected as unusable. Only the keys people
/// actually put in shortcuts are listed; anything else falls back to the
/// character the keyboard reported.
public func shortcutKeyName(forKeyCode code: UInt32) -> String? {
    switch code {
    case 36:  return "↩"
    case 48:  return "⇥"
    case 49:  return "Space"
    case 51:  return "⌫"
    case 53:  return "⎋"
    case 76:  return "⌤"
    case 115: return "↖"
    case 116: return "⇞"
    case 117: return "⌦"
    case 119: return "↘"
    case 121: return "⇟"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    case 122: return "F1"
    case 120: return "F2"
    case 99:  return "F3"
    case 118: return "F4"
    case 96:  return "F5"
    case 97:  return "F6"
    case 98:  return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    default:  return nil
    }
}
