import AppKit
import ClipdCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var watcher: PasteboardWatcher!
    private var hotKey: HotKey?
    private var panelController: PanelController!
    let history = History()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Clipd"
        rebuildMenu()

        watcher = PasteboardWatcher(
            onCapture: { [weak self] item in
                guard let self else { return }
                self.history.add(item)
                // Types and counts only, never the value.
                //
                // %{public} is required. Unified logging redacts every string
                // argument as <private> by default, which makes the diagnostic
                // unreadable and indistinguishable from "nothing happened".
                // Safe here because no clipboard value is ever passed in.
                Diag.capture.info("""
                    captured \(item.text.count, privacy: .public) chars from \
                    \(item.sourceBundleID ?? "unknown", privacy: .public), \
                    \(self.history.items.count, privacy: .public) in history
                    """)
                self.rebuildMenu()
            },
            onRefusal: { [weak self] reason in
                guard let self else { return }
                Diag.capture.info("refused: \(String(describing: reason), privacy: .public)")
                // Privacy layer 2, the auto-clear tombstone. Measured:
                // Passwords.app wipes the clipboard 60.0s and 60.9s after a
                // copy, and no ordinary app cleared the clipboard even once in
                // 390 seconds of real use. So a clear shortly after a capture
                // is a strong signal the captured item was a secret we failed
                // to recognise. 90s rather than 60s, because "about a minute"
                // is not exact and the margin is free.
                if case .emptyChange = reason,
                   let newest = self.history.items.first,
                   Date().timeIntervalSince(newest.createdAt) < 90 {
                    self.history.removeMostRecent()
                    Diag.capture.info("retracted the most recent item after a clipboard clear (auto-clear rule)")
                    self.rebuildMenu()
                }
            })
        watcher.start()

        panelController = PanelController(history: history)
        hotKey = HotKey { [weak self] in
            self?.panelController.toggle()
        }
        if hotKey == nil {
            // Measured: two apps CAN both register the same hotkey and both
            // fire, so this is not the only way coexistence goes wrong.
            Diag.panel.error("Cmd+Shift+V is already taken. If the real Paste app is running, quit it.")
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(
            title: "Clipd \(ClipdCore.version), \(history.items.count) items",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for item in history.items.prefix(5) {
            menu.addItem(NSMenuItem(title: String(item.preview.prefix(50)),
                                    action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clipd", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only. Rejected: .regular, which puts an icon in the Dock and
// gives the app a main menu it has no use for.
app.setActivationPolicy(.accessory)
app.run()
