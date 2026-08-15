import AppKit
import UniformTypeIdentifiers

/// Privacy settings: which apps are never recorded, and the auto-clear rule.
final class PrivacyPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: AppSettings
    private var table: NSTableView!
    private var ids: [String] = []

    init(settings: AppSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = "Privacy"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 400))

        let autoClear = NSButton(checkboxWithTitle: "Forget an item if the clipboard is cleared soon after",
                                 target: self, action: #selector(toggleAutoClear(_:)))
        autoClear.frame = NSRect(x: 24, y: 356, width: 420, height: 20)
        autoClear.state = settings.autoClearEnabled ? .on : .off
        root.addSubview(autoClear)

        let explain = NSTextField(wrappingLabelWithString:
            "Password managers wipe the clipboard about a minute after you copy. "
            + "Treating that as a signal catches managers that are not in the list below.")
        explain.frame = NSRect(x: 42, y: 316, width: 400, height: 34)
        explain.font = .systemFont(ofSize: 11)
        explain.textColor = .secondaryLabelColor
        root.addSubview(explain)

        let listTitle = NSTextField(labelWithString: "Never record copies from")
        listTitle.frame = NSRect(x: 24, y: 282, width: 300, height: 18)
        listTitle.font = .boldSystemFont(ofSize: 13)
        root.addSubview(listTitle)

        let warning = NSTextField(wrappingLabelWithString:
            "Apple's Passwords app does not mark its copies as confidential, so for "
            + "that app this list is the only protection.")
        warning.frame = NSRect(x: 24, y: 242, width: 412, height: 34)
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .secondaryLabelColor
        root.addSubview(warning)

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 60, width: 412, height: 174))
        table = NSTableView(frame: scroll.bounds)
        let column = NSTableColumn(identifier: .init("app"))
        column.width = 390
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        root.addSubview(scroll)

        let add = NSButton(title: "Add...", target: self, action: #selector(addApp))
        add.frame = NSRect(x: 24, y: 20, width: 90, height: 28)
        add.bezelStyle = .rounded
        root.addSubview(add)

        let remove = NSButton(title: "Remove", target: self, action: #selector(removeApp))
        remove.frame = NSRect(x: 120, y: 20, width: 90, height: 28)
        remove.bezelStyle = .rounded
        root.addSubview(remove)

        reload()
        // Without this the tab controller stretches the pane to fill an
        // oversized window and the content sinks to the bottom, because these
        // subviews are laid out from the bottom edge.
        preferredContentSize = NSSize(width: 460, height: 400)
        for sub in root.subviews { sub.autoresizingMask = [.minYMargin] }
        view = root
    }

    private func reload() {
        ids = settings.ignoredBundleIDs.sorted()
        table?.reloadData()
    }

    @objc private func toggleAutoClear(_ sender: NSButton) {
        settings.autoClearEnabled = sender.state == .on
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        // A file picker, not a text field. Nobody knows their password
        // manager's bundle identifier, and a typo in a deny-list is a silent
        // failure that only shows up as a leaked password.
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        settings.addIgnored(id)
        reload()
    }

    @objc private func removeApp() {
        guard table.selectedRow >= 0, table.selectedRow < ids.count else { return }
        settings.removeIgnored(ids[table.selectedRow])
        reload()
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? {
                let v = NSTableCellView()
                v.identifier = id
                let image = NSImageView(frame: NSRect(x: 2, y: 2, width: 20, height: 20))
                v.addSubview(image)
                v.imageView = image
                let text = NSTextField(labelWithString: "")
                text.frame = NSRect(x: 28, y: 3, width: 350, height: 18)
                v.addSubview(text)
                v.textField = text
                return v
            }()
        let bundleID = ids[row]
        // Show the human name where macOS knows it, and the raw id otherwise,
        // so an entry for an app you have uninstalled is still identifiable.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
            cell.textField?.stringValue = FileManager.default.displayName(atPath: url.path)
        } else {
            cell.imageView?.image = NSImage(systemSymbolName: "questionmark.app",
                                            accessibilityDescription: nil)
            cell.textField?.stringValue = bundleID
        }
        return cell
    }
}
