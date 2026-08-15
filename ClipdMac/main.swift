import AppKit
import ClipdCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Clipd"

        let menu = NSMenu()
        let version = NSMenuItem(title: "Clipd \(ClipdCore.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clipd", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only. Rejected: .regular, which puts an icon in the Dock and
// gives the app a main menu it has no use for.
app.setActivationPolicy(.accessory)
app.run()
