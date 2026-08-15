import AppKit
import ClipdCore

/// A borderless panel refuses to become key by default, and the search field
/// then silently receives nothing at all. This override is not optional.
private final class ClipdPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSTextFieldDelegate,
                             NSTableViewDataSource, NSTableViewDelegate {
    private let history: History
    private var panel: ClipdPanel!
    private var field: NSTextField!
    private var banner: NSTextField!
    private var table: NSTableView!
    private var results: [HistoryItem] = []

    /// The app that was frontmost when the panel opened. Everything depends on
    /// putting it back before pasting.
    private(set) var previousApp: NSRunningApplication?

    var onCommit: ((HistoryItem, NSRunningApplication?) -> Void)?

    init(history: History) {
        self.history = history
        super.init()
        build()
    }

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: 760, height: 360)
        panel = ClipdPanel(contentRect: rect,
                           styleMask: [.nonactivatingPanel, .borderless],
                           backing: .buffered, defer: false)
        // .screenSaver so it appears above a fullscreen app. Measured working.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let content = NSView(frame: rect)

        // The loud failure. Without Accessibility, macOS discards every
        // synthesised event and reports nothing, so the app looks perfectly
        // healthy while pasting nothing. This deliberately contradicts every
        // other success signal on screen.
        banner = NSTextField(labelWithString: "")
        banner.frame = NSRect(x: 16, y: 312, width: 728, height: 32)
        banner.font = .boldSystemFont(ofSize: 13)
        banner.textColor = .white
        banner.backgroundColor = .systemOrange
        banner.drawsBackground = true
        banner.alignment = .center
        banner.isHidden = true
        content.addSubview(banner)

        field = NSTextField(frame: NSRect(x: 16, y: 312, width: 728, height: 32))
        field.placeholderString = "Search clipboard history"
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.focusRingType = .none
        content.addSubview(field)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 728, height: 284))
        table = NSTableView(frame: scroll.bounds)
        let column = NSTableColumn(identifier: .init("preview"))
        column.width = 700
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        content.addSubview(scroll)

        panel.contentView = content
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { dismiss(); return }
        show()
    }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        field.stringValue = ""
        reload()
        updateTrustBanner()

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - 380, y: visible.minY + 60))
        }

        // Activating is what Spotlight, Alfred and Raycast all do. A background
        // app's panel cannot take key focus without it. The previous app is
        // restored on dismiss.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        // NEVER read panel.isKeyWindow here. Activation is asynchronous and
        // measures false in this same runloop turn, which looks exactly like a
        // hard failure. It becomes true within 10ms.
        // Trust state belongs in this line. Without it, an untrusted launch
        // looks identical to a broken search field: the field is hidden, so
        // nothing can be typed, and no later diagnostic ever fires.
        Diag.panel.info("opened, previous app \(self.previousApp?.bundleIdentifier ?? "nil", privacy: .public), \(self.results.count, privacy: .public) results, accessibilityTrusted \(AXIsProcessTrusted(), privacy: .public)")
    }

    func dismiss() {
        panel.orderOut(nil)
        field.stringValue = ""
        previousApp?.activate()
    }

    /// Accessibility failure is invisible: macOS discards synthesised events
    /// with no error at all.
    func updateTrustBanner() {
        let trusted = AXIsProcessTrusted()
        banner.isHidden = trusted
        field.isHidden = !trusted
        if !trusted {
            banner.stringValue = "PASTE DISABLED. Grant Clipd Accessibility in "
                + "System Settings, Privacy and Security."
        }
    }

    private func reload() {
        results = history.search(field.stringValue)
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
            return true
        default:
            return false
        }
    }

    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = min(max(current + delta, 0), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func commitSelection() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { dismiss(); return }
        let chosen = results[row]
        let target = previousApp
        panel.orderOut(nil)
        field.stringValue = ""
        onCommit?(chosen, target)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingTail
                f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                return f
            }()
        let item = results[row]
        let source = item.sourceName ?? "unknown"
        cell.stringValue = "\(source.padding(toLength: 14, withPad: " ", startingAt: 0))  \(item.preview)"
        return cell
    }
}
