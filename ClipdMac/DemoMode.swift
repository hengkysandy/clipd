import Foundation

/// A throwaway instance of Clipd, pointed at a database that is not yours.
///
/// Set `CLIPD_SUPPORT_DIR` to a scratch directory and launch the binary
/// directly:
///
///     CLIPD_SUPPORT_DIR=/tmp/clipd-demo \
///       .build/xcode/Build/Products/Release/ClipdMac.app/Contents/MacOS/ClipdMac
///
/// This is how the screenshots in the README are produced. Everything on screen
/// is invented sample content, so publishing an image cannot publish anything
/// that was really copied. It is also the safe way to try a schema change
/// without putting your own history at risk.
///
/// Two things are switched off when it is on, and both are the point rather
/// than a precaution:
///
/// - **Sync.** The R2 credentials live in the Keychain, not in the support
///   directory, so a demo instance would otherwise authenticate happily and
///   pull the real history down into the scratch database. That is exactly the
///   content the demo exists to keep off the screen.
/// - **Reading and writing those credentials at all.** Without this the Sync
///   settings pane fills in the real account id and access key id, which is
///   the one pane most likely to be screenshotted, and the Save button can
///   overwrite the real values from a form that was only ever a prop.
enum DemoMode {
    static var isOn: Bool {
        ProcessInfo.processInfo.environment["CLIPD_SUPPORT_DIR"]?.isEmpty == false
    }

    /// Where the database and the encrypted blobs live.
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLIPD_SUPPORT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
            .appendingPathComponent("Clipd")
    }
}
