import Foundation
import ClipdCore

/// User settings, persisted in UserDefaults.
///
/// Rejected: storing these in the encrypted database. Settings are not secret,
/// and putting them there would mean the app cannot read its own configuration
/// until the Keychain unlocks.
final class AppSettings {
    private enum Key {
        static let retention = "clipd.retention"
        static let autoClear = "clipd.autoClearEnabled"
        static let ignored = "clipd.ignoredBundleIDs"
        static let ignoredSeeded = "clipd.ignoredSeeded"
        static let autoSync = "clipd.autoSyncEnabled"
    }

    /// Measured: Apple's Passwords.app sets no concealed marker at all, so for
    /// that app this list is the only defence. Bitwarden does set a marker and
    /// is listed anyway, as a second line.
    static let seedIgnored: Set<String> = [
        "com.apple.passwords",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.1password.1password",
    ]

    private let defaults: UserDefaults

    /// Fires on every change. The watcher rebuilds its capture settings from
    /// this, so a change that does not fire would take effect only after a
    /// restart, which reads as the setting not working.
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Seed once, and record that we did. Without the marker, a user who
        // deliberately empties the list would find it refilled on next launch.
        if !defaults.bool(forKey: Key.ignoredSeeded) {
            defaults.set(Array(Self.seedIgnored), forKey: Key.ignored)
            defaults.set(true, forKey: Key.ignoredSeeded)
        }
    }

    var retention: RetentionPolicy {
        get {
            guard let raw = defaults.string(forKey: Key.retention),
                  let policy = RetentionPolicy(rawValue: raw) else { return .forever }
            return policy
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.retention)
            onChange?()
        }
    }

    var autoClearEnabled: Bool {
        get {
            // Defaults to on. Measured: zero false positives across 390
            // seconds of ordinary use, and it is the layer that catches
            // password managers not on the deny-list.
            if defaults.object(forKey: Key.autoClear) == nil { return true }
            return defaults.bool(forKey: Key.autoClear)
        }
        set {
            defaults.set(newValue, forKey: Key.autoClear)
            onChange?()
        }
    }

    /// Defaults to on. Sync only ever runs when credentials are configured, so
    /// this does nothing until the user sets sync up deliberately.
    var autoSyncEnabled: Bool {
        get {
            if defaults.object(forKey: Key.autoSync) == nil { return true }
            return defaults.bool(forKey: Key.autoSync)
        }
        set {
            defaults.set(newValue, forKey: Key.autoSync)
            onChange?()
        }
    }

    var ignoredBundleIDs: Set<String> {
        Set((defaults.array(forKey: Key.ignored) as? [String] ?? []).map { $0.lowercased() })
    }

    func addIgnored(_ id: String) {
        var current = ignoredBundleIDs
        current.insert(id.lowercased())
        defaults.set(Array(current), forKey: Key.ignored)
        onChange?()
    }

    func removeIgnored(_ id: String) {
        var current = ignoredBundleIDs
        current.remove(id.lowercased())
        defaults.set(Array(current), forKey: Key.ignored)
        onChange?()
    }

    /// What the watcher actually uses.
    var captureSettings: CaptureSettings {
        CaptureSettings(deniedBundleIDs: ignoredBundleIDs,
                        maxBytes: CaptureSettings.standard.maxBytes)
    }
}
