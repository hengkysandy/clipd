import AppKit

/// Feedback sounds for capture and paste, each independently chosen.
///
/// Uses the sounds already in /System/Library/Sounds rather than bundled audio,
/// so project.yml needs no resources block and the sounds match the rest of the
/// OS. All 14 were verified to load through NSSound(named:).
///
/// Copy and paste are separate settings on purpose. A tick on every Cmd+C is
/// intrusive for anyone who copies constantly, while a sound on paste is rare
/// enough to be useful, so most people will want different answers for the two.
@MainActor
enum Sounds {

    /// `nil` name means silent. Rejected: a single on/off switch, which forced
    /// the same answer for a common event and a rare one.
    enum Slot: String {
        case capture = "clipd.sound.capture"
        case paste = "clipd.sound.paste"

        var defaultName: String? {
            switch self {
            // Copy happens constantly, so it starts silent. Paste is
            // deliberate and infrequent, so it starts with a quiet click.
            case .capture: return nil
            case .paste: return "Pop"
            }
        }
    }

    /// Every sound macOS ships, verified present.
    static let available = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
                            "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi",
                            "Submarine", "Tink"]

    private static var cache: [String: NSSound] = [:]

    static func name(for slot: Slot) -> String? {
        // A stored empty string means the user explicitly chose Off, which is
        // different from never having chosen at all.
        guard let stored = UserDefaults.standard.string(forKey: slot.rawValue) else {
            return slot.defaultName
        }
        return stored.isEmpty ? nil : stored
    }

    static func setName(_ name: String?, for slot: Slot) {
        UserDefaults.standard.set(name ?? "", forKey: slot.rawValue)
    }

    static func play(_ slot: Slot) {
        guard let name = name(for: slot) else { return }
        play(named: name)
    }

    /// Used both for real feedback and for previewing a choice in the menu.
    static func play(named name: String) {
        let sound: NSSound?
        if let hit = cache[name] {
            sound = hit
        } else {
            // Loaded once and reused. NSSound re-reads from disk on every
            // init, which stutters when copying quickly.
            sound = NSSound(named: name)
            if let sound { cache[name] = sound }
        }
        sound?.stop()      // so rapid repeats retrigger rather than overlap
        sound?.play()
    }

    static func captured() { play(.capture) }
    static func pasted() { play(.paste) }
}
