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
        static let showOnboarding = "clipd.showAccessibilityOnboarding"
        static let linkPreviews = "clipd.linkPreviewsEnabled"
        static let panelShortcut = "clipd.panelShortcut"
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

    /// The global shortcut that opens the panel.
    ///
    /// Falls back to Cmd+Shift+V when the stored value is missing or does not
    /// parse. Rejected: refusing to start with a broken value, which would
    /// leave the app with no way to open its own panel and no way to fix it.
    var panelShortcut: Shortcut {
        get {
            guard let raw = defaults.string(forKey: Key.panelShortcut),
                  let shortcut = Shortcut(encoded: raw) else { return .panelDefault }
            return shortcut
        }
        set {
            defaults.set(newValue.encoded, forKey: Key.panelShortcut)
            // Deliberately does NOT fire onChange. The hotkey is re-registered
            // by the code that sets this, because that is the only place that
            // can tell the user when macOS refuses it.
        }
    }

    /// Whether a link card may fetch the page's picture and title.
    ///
    /// Off by default, and this is the one default in the app that is worth
    /// arguing about. Turning it on makes Clipd talk to servers the user does
    /// not own, which nothing else in the app does: it is otherwise a local
    /// database plus a bucket the user pays for. A default of on would quietly
    /// change what the app is, on an update, for people who never asked for
    /// thumbnails. So it starts off and the Privacy pane explains it.
    var linkPreviewsEnabled: Bool {
        get { defaults.bool(forKey: Key.linkPreviews) }
        set {
            defaults.set(newValue, forKey: Key.linkPreviews)
            onChange?()
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

    /// Whether first run explains the Accessibility permission.
    ///
    /// Defaults to on, and it is only ever consulted while the permission is
    /// missing, so somebody who has granted it never sees the window again
    /// whatever this says. The opt out exists for the person who deliberately
    /// runs Clipd as a history recorder with no pasting: for them the window
    /// would be a nag about a permission they have decided not to give.
    var showAccessibilityOnboarding: Bool {
        get {
            if defaults.object(forKey: Key.showOnboarding) == nil { return true }
            return defaults.bool(forKey: Key.showOnboarding)
        }
        set {
            defaults.set(newValue, forKey: Key.showOnboarding)
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
