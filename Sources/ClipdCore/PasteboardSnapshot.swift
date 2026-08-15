/// A plain description of one clipboard change.
///
/// The shell reads NSPasteboard and fills this in. Core never sees AppKit, so
/// every capture rule is testable with no clipboard, no permission and no
/// running app.
public struct PasteboardSnapshot: Equatable, Sendable {
    /// Every type identifier present, across all items.
    public let types: [String]
    /// Total bytes across every type on every item.
    public let totalBytes: Int
    /// Zero means the clipboard was cleared. That is a real, common event.
    public let itemCount: Int
    /// The frontmost app when the change was noticed. Meaningless when
    /// `itemCount` is zero, which is why the empty check runs first.
    public let sourceBundleID: String?

    public init(types: [String], totalBytes: Int, itemCount: Int,
                sourceBundleID: String?) {
        self.types = types
        self.totalBytes = totalBytes
        self.itemCount = itemCount
        self.sourceBundleID = sourceBundleID
    }
}

public struct CaptureSettings: Equatable, Sendable {
    /// Compared case insensitively. Bundle ids are case insensitive on macOS
    /// and a deny-list that misses on capitalisation is a silent password leak.
    public let deniedBundleIDs: Set<String>
    public let maxBytes: Int

    public init(deniedBundleIDs: Set<String>, maxBytes: Int) {
        self.deniedBundleIDs = Set(deniedBundleIDs.map { $0.lowercased() })
        self.maxBytes = maxBytes
    }

    /// Apple's Passwords.app was measured setting NO marker at all, so the
    /// deny-list is the only thing standing between it and the database.
    /// Bitwarden does set a marker, and is listed anyway as a second defence.
    public static let standard = CaptureSettings(
        deniedBundleIDs: [
            "com.apple.passwords",
            "com.apple.keychainaccess",
            "com.bitwarden.desktop",
            "com.1password.1password",
        ],
        maxBytes: 10 * 1024 * 1024)
}
