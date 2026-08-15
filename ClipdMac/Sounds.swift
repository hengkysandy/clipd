import AppKit

/// Short feedback sounds for capture and paste.
///
/// Uses the system sounds in /System/Library/Sounds rather than bundled audio,
/// so there is no resources block in project.yml for two clicks and the sounds
/// already match the rest of the OS.
///
/// Rejected: playing a sound on every capture with no way to turn it off. A
/// tick on every Cmd+C is intrusive for anyone who copies constantly, so this
/// is a toggle and the preference persists.
@MainActor
enum Sounds {
    private static let defaultsKey = "clipd.soundEnabled"

    /// Defaults to on, because the sounds were asked for. Turning them off is
    /// one click in the menu bar.
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    // Loaded once. NSSound reloads from disk on every init otherwise, which
    // stutters when you copy quickly.
    private static let captureSound = NSSound(named: "Tink")
    private static let pasteSound = NSSound(named: "Pop")

    static func captured() {
        guard enabled else { return }
        captureSound?.stop()       // so rapid copies retrigger rather than overlap
        captureSound?.play()
    }

    static func pasted() {
        guard enabled else { return }
        pasteSound?.stop()
        pasteSound?.play()
    }
}
