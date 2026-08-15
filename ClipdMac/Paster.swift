import AppKit

enum Paster {
    /// Restores focus to `app`, then posts Cmd+V.
    ///
    /// Returns false if Accessibility is not granted, in which case macOS
    /// silently discards the event and the app would otherwise look healthy
    /// while doing nothing.
    @MainActor
    @discardableResult
    static func paste(_ text: String, into app: NSRunningApplication?) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let app {
            app.activate()
            // Measured at 0ms on an idle machine, because ordering the panel
            // out already returned focus. The loop stays anyway: a slow or busy
            // app is exactly the case that would send Cmd+V to the wrong
            // window, and that failure is indistinguishable from "paste is
            // broken".
            let deadline = Date().addingTimeInterval(1.5)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier
                    != app.processIdentifier, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }

        guard AXIsProcessTrusted() else {
            Diag.paste.error("cannot paste, Accessibility not granted. macOS discards synthesised events with no error.")
            return false
        }

        // kVK_ANSI_V is 0x09. Measured working against TextEdit, verified by
        // reading the target document back rather than by eye.
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            Diag.paste.error("could not build the key events")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        return true
    }
}
