import Testing
import Foundation
@testable import ClipdCore

@Test("The default is Cmd+Shift+V, which is what the app has always used")
func defaultShortcut() {
    #expect(Shortcut.panelDefault.display == "⇧⌘V")
    #expect(Shortcut.panelDefault.isUsable)
}

@Test("Modifiers print in the order macOS prints them")
func displayOrder() {
    let all = Shortcut(keyCode: 9, modifiers: [.command, .shift, .option, .control],
                       label: "V")
    #expect(all.display == "⌃⌥⇧⌘V")
    #expect(Shortcut(keyCode: 49, modifiers: [.option], label: "Space").display == "⌥Space")
}

@Test("A shortcut with no real modifier is refused")
func refusesUnusableShortcuts() {
    // Registering plain V globally means nobody can type V in any app again,
    // and the panel opens while you type. Shift alone is the same trap.
    #expect(!Shortcut(keyCode: 9, modifiers: [], label: "V").isUsable)
    #expect(!Shortcut(keyCode: 9, modifiers: [.shift], label: "V").isUsable)
    // Any one of the three real modifiers is enough.
    #expect(Shortcut(keyCode: 9, modifiers: [.control], label: "V").isUsable)
    #expect(Shortcut(keyCode: 9, modifiers: [.option], label: "V").isUsable)
    #expect(Shortcut(keyCode: 9, modifiers: [.command], label: "V").isUsable)
}

@Test("A shortcut with no label is refused, because it would print as nothing")
func refusesEmptyLabel() {
    #expect(!Shortcut(keyCode: 9, modifiers: [.command], label: "").isUsable)
}

@Test("A shortcut survives the round trip through storage")
func storageRoundTrip() throws {
    let original = Shortcut(keyCode: 100, modifiers: [.control, .option], label: "F8")
    let restored = try #require(Shortcut(encoded: original.encoded))
    #expect(restored == original)
}

@Test("A key that prints a pipe still round trips")
func labelWithASeparatorInIt() throws {
    // The label is never split, so the separator inside it is safe. If this
    // ever breaks, the stored shortcut decodes to nil and the app silently
    // falls back to the default, which reads as "my setting was forgotten".
    let original = Shortcut(keyCode: 42, modifiers: [.command], label: "|")
    #expect(try #require(Shortcut(encoded: original.encoded)) == original)
}

@Test("Rubbish in storage decodes to nothing rather than to a wrong shortcut")
func rejectsRubbish() {
    #expect(Shortcut(encoded: "") == nil)
    #expect(Shortcut(encoded: "9|3") == nil)
    #expect(Shortcut(encoded: "nine|3|V") == nil)
    #expect(Shortcut(encoded: "9|three|V") == nil)
    // An empty label would be a shortcut that prints as bare modifiers.
    #expect(Shortcut(encoded: "9|3|") == nil)
}

@Test("Keys that print nothing get a name, so they can be shown")
func namesForBlankKeys() {
    #expect(shortcutKeyName(forKeyCode: 49) == "Space")
    #expect(shortcutKeyName(forKeyCode: 96) == "F5")
    #expect(shortcutKeyName(forKeyCode: 126) == "↑")
    // A letter key is not in the table: its own character is the right label.
    #expect(shortcutKeyName(forKeyCode: 9) == nil)
}
