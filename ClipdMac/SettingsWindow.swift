import AppKit
import ClipdCore

/// The Settings window.
///
/// NSTabViewController in toolbar style is the standard macOS settings look
/// with no custom chrome. Rejected: a hand built sidebar, which is more code
/// and would drift from the system appearance at the next macOS release.
final class SettingsWindowController: NSWindowController {
    private let settings: AppSettings
    private let onErase: () -> Void

    init(settings: AppSettings,
         onErase: @escaping () -> Void,
         onRecordShortcut: @escaping (Shortcut) -> Bool,
         onShortcutRecording: @escaping (Bool) -> Void,
         lastSync: @escaping () -> (Date?, String?),
         onSyncNow: @escaping (R2Credentials, String, @escaping (String) -> Void) -> Void) {
        self.settings = settings
        self.onErase = onErase

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addChild(GeneralPane(settings: settings, onErase: onErase,
                                  onRecordShortcut: onRecordShortcut,
                                  onShortcutRecording: onShortcutRecording))
        tabs.addChild(PrivacyPane(settings: settings))
        tabs.addChild(SyncPane(settings: settings, lastSync: lastSync, onSyncNow: onSyncNow))

        // The icon lives on the tab view ITEM, not on the view controller.
        // NSViewController has no image property, and without one the toolbar
        // draws an empty box above every label.
        let symbols = ["gearshape", "hand.raised", "arrow.triangle.2.circlepath"]
        for (item, symbol) in zip(tabs.tabViewItems, symbols) {
            item.image = NSImage(systemSymbolName: symbol,
                                 accessibilityDescription: item.label)
        }

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
