import AppKit
import ApplicationServices

/// Watches the Accessibility permission and reports the moment it changes.
///
/// This is what removes the quit and reopen step from first run. Nothing about
/// macOS requires that restart: `AXIsProcessTrusted()` starts returning true
/// for a process that is already running, as soon as the switch is turned on.
/// The app just never looked again. The menu bar kept its orange warning icon
/// and pasting kept failing, which reads exactly like "the grant did not take,
/// try restarting it".
///
/// Two signals, because neither is enough on its own:
///
/// - `com.apple.accessibility.api` is a distributed notification macOS posts
///   when the trust database changes. It arrives almost at once, which is what
///   makes the window feel live. It carries no payload and Apple documents no
///   contract around it, so it is treated as a hint, not as the answer.
/// - A one second poll, as the fallback that does not depend on that hint. The
///   work is one boolean read, so it is cheaper than the timer that already
///   redraws the pause glyph every second.
///
/// Rejected: checking only when the onboarding window becomes key. The status
/// icon and the panel banner are both wrong until something notices, and the
/// user may never bring that window forward again.
@MainActor
final class AccessibilityMonitor {
    private let probe: () -> Bool
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// The last value seen. Read this rather than calling the API again, so
    /// every part of the UI agrees about what it is showing.
    private(set) var isTrusted: Bool

    /// Fires on a change only, never on every tick, so callers can rebuild
    /// menus and windows from it without checking whether anything moved.
    var onChange: ((Bool) -> Void)?

    /// The probe is injectable so the change logic can be tested without a real
    /// permission, which no test suite can grant itself.
    init(probe: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.probe = probe
        self.isTrusted = probe()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main) { [weak self] _ in
                // The notification can land a moment before the API agrees, so
                // this re-reads rather than assuming the change is a grant.
                MainActor.assumeIsolated { self?.check() }
            }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
    }

    /// Re-reads now and reports a change if there was one.
    func check() {
        let now = probe()
        guard now != isTrusted else { return }
        isTrusted = now
        Diag.panel.info("accessibility permission changed, trusted now \(now, privacy: .public)")
        onChange?(now)
    }

    // MARK: - Asking for it

    /// Shows the system permission dialog and puts Clipd in the list.
    ///
    /// Without this the first prompt arrives at the first paste, which is the
    /// worst possible moment: the user has already opened the panel and picked
    /// an item, and the paste they asked for silently does not happen.
    static func prompt() {
        // The literal, not `kAXTrustedCheckOptionPrompt`. That constant is
        // imported as a global var, which Swift 6 strict concurrency refuses
        // as shared mutable state. The string is the constant's value and has
        // been stable since this API shipped.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Opens System Settings on the Accessibility list.
    ///
    /// The system dialog has its own button for this, but it is one more thing
    /// to read and dismiss, and it does not reappear once it has been shown
    /// during this login session. Our own button always works.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Quits and reopens Clipd, in one click.
    ///
    /// The fallback, not the plan. Live detection is expected to make this
    /// unnecessary, but if macOS ever does hold a stale answer for a running
    /// process, the user should press one button rather than be told to quit
    /// the app and open it again themselves.
    ///
    /// Termination happens in the completion handler. Calling `terminate`
    /// straight after `openApplication` races the launch and can leave the user
    /// with no app at all.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Diag.panel.error("relaunch failed: \(String(describing: error), privacy: .public)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
