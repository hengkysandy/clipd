import AppKit
import Carbon.HIToolbox
import ClipdCore

extension Shortcut {
    /// The same shortcut in the numbers Carbon wants for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var out: UInt32 = 0
        if modifiers.contains(.command) { out |= UInt32(cmdKey) }
        if modifiers.contains(.shift)   { out |= UInt32(shiftKey) }
        if modifiers.contains(.option)  { out |= UInt32(optionKey) }
        if modifiers.contains(.control) { out |= UInt32(controlKey) }
        return out
    }

    /// What the user just pressed, or nil if they pressed something that cannot
    /// be a shortcut on its own.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var mods: ShortcutModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        let code = UInt32(event.keyCode)
        // The name first, because Space and the arrows report characters that
        // would print as nothing or as a box.
        let label = shortcutKeyName(forKeyCode: code)
            ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty, !label.allSatisfy(\.isWhitespace) else { return nil }
        self.init(keyCode: code, modifiers: mods, label: label)
    }
}

/// A click-then-press control for recording a global shortcut.
///
/// Rejected: a text field where you type "cmd+shift+v". It cannot tell a key's
/// position from its letter, so it breaks on any non-US layout, and it lets you
/// save a combination that macOS will refuse to register.
final class ShortcutField: NSView {
    /// Asked to store and register the new shortcut. Returns false if macOS
    /// refused it, which happens when another app already holds it.
    var onRecord: ((Shortcut) -> Bool)?
    /// True while listening. The app releases its own hotkey for this, or
    /// pressing the current shortcut would open the panel instead of being
    /// recorded, and the one combination you could never record would be the
    /// one you are trying to change.
    var onRecordingChanged: ((Bool) -> Void)?

    private var shortcut: Shortcut
    private var isRecording = false {
        didSet {
            onRecordingChanged?(isRecording)
            redraw()
        }
    }
    private let label = NSTextField(labelWithString: "")

    init(frame: NSRect, shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.frame = NSRect(x: 4, y: (frame.height - 18) / 2, width: frame.width - 8, height: 18)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        addSubview(label)
        redraw()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Puts a shortcut in without recording it. Used by the Reset button.
    func show(_ shortcut: Shortcut) {
        self.shortcut = shortcut
        redraw()
    }

    private func redraw() {
        label.stringValue = isRecording ? "Press keys..." : shortcut.display
        label.textColor = isRecording ? .secondaryLabelColor : .labelColor
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor
                                          : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    /// Cmd and Ctrl combinations never reach `keyDown`.
    ///
    /// They go down the key equivalent path first, and something else in the
    /// window (or the menu bar) claims them. Measured the obvious way: without
    /// this override, recording Cmd+Shift+K did nothing at all while plain
    /// F5 recorded fine. Returning true consumes the event so it cannot also
    /// trigger whatever it normally would.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    /// Live feedback while the modifiers are held but no key has been pressed.
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let held = Shortcut(keyCode: 0, modifiers: modifiers(from: event), label: "")
        label.stringValue = held.display.isEmpty ? "Press keys..." : held.display
    }

    private func modifiers(from event: NSEvent) -> ShortcutModifiers {
        var mods: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { mods.insert(.command) }
        if event.modifierFlags.contains(.shift)   { mods.insert(.shift) }
        if event.modifierFlags.contains(.option)  { mods.insert(.option) }
        if event.modifierFlags.contains(.control) { mods.insert(.control) }
        return mods
    }

    private func capture(_ event: NSEvent) {
        // Escape with nothing held means "stop, keep what was there".
        if event.keyCode == 53, modifiers(from: event).isEmpty {
            isRecording = false
            redraw()
            return
        }
        guard let candidate = Shortcut(event: event) else { return }
        guard candidate.isUsable else {
            // Say why. A control that silently ignores the key you pressed is
            // indistinguishable from one that is broken.
            label.stringValue = "Add ⌘, ⌥ or ⌃"
            return
        }
        // Record first, stop second. The other order briefly puts the OLD
        // shortcut back (stopping unpauses the app's hotkey) and then replaces
        // it, so macOS is asked to register twice for one keypress. Measured in
        // the log: two "panel shortcut registered" lines per change.
        guard onRecord?(candidate) == true else {
            label.stringValue = "Already taken"
            return
        }
        shortcut = candidate
        isRecording = false
        redraw()
    }
}
