import AppKit

/// The Settings window.
///
/// NSTabViewController in toolbar style is the standard macOS settings look
/// with no custom chrome. Rejected: a hand built sidebar, which is more code
/// and would drift from the system appearance at the next macOS release.
final class SettingsWindowController: NSWindowController {
    private let settings: AppSettings
    private let onErase: () -> Void

    init(settings: AppSettings, onErase: @escaping () -> Void) {
        self.settings = settings
        self.onErase = onErase

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addChild(GeneralPane(settings: settings, onErase: onErase))
        tabs.addChild(PrivacyPane(settings: settings))

        let window = NSWindow(contentViewController: tabs)
        window.title = "Clipd Settings"
        window.styleMask = [.titled, .closable]
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // The app is .accessory, so without this the window opens behind
        // whatever the user was doing and looks like nothing happened.
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
