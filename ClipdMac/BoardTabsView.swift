import AppKit
import ClipdCore

/// The row of board tabs across the top of the panel.
///
/// Drawn as plain buttons in a row rather than an NSSegmentedControl, because
/// each tab needs its own colour dot and a right click menu, neither of which a
/// segmented control gives you.
final class BoardTabsView: NSView {
    var onSelect: ((UUID?) -> Void)?
    var onCreate: (() -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?

    private var boards: [Pinboard] = []
    private var selected: UUID?

    static func color(named name: String) -> NSColor {
        switch BoardColor(rawValue: name) {
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .teal: return .systemTeal
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case nil:
            // Retired palette entries keep their old colour. A board made
            // before red left the palette must not silently turn grey: the user
            // named it, filed things on it, and never asked for it to change.
            if name == "red" { return .systemRed }
            return .systemGray
        }
    }

    func update(boards: [Pinboard], selected: UUID?) {
        self.boards = boards
        self.selected = selected
        rebuild()
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0

        x = addTab(title: "Clipboard", dot: nil, id: nil, at: x)
        for board in boards {
            x = addTab(title: board.name, dot: BoardTabsView.color(named: board.colorName),
                       id: board.id, at: x)
        }

        let plus = NSButton(title: "+", target: self, action: #selector(create))
        plus.frame = NSRect(x: x + 4, y: 2, width: 28, height: 26)
        plus.bezelStyle = .inline
        plus.isBordered = false
        plus.font = .systemFont(ofSize: 17, weight: .light)
        plus.contentTintColor = .secondaryLabelColor
        plus.toolTip = "New pinboard"
        addSubview(plus)
    }

    private func addTab(title: String, dot: NSColor?, id: UUID?, at x: CGFloat) -> CGFloat {
        let hasDot = dot != nil
        let textWidth = (title as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let width = textWidth + (hasDot ? 34 : 20)

        let button = NSButton(title: title, target: self, action: #selector(select(_:)))
        button.frame = NSRect(x: x, y: 0, width: width, height: 30)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.identifier = NSUserInterfaceItemIdentifier(id?.uuidString ?? "")
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        let isSelected = id == selected
        button.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
            : NSColor.clear.cgColor
        button.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        if hasDot { button.imagePosition = .imageLeading }
        addSubview(button)

        if let dot {
            let size: CGFloat = 9
            let circle = NSView(frame: NSRect(x: x + 10, y: 15 - size / 2,
                                              width: size, height: size))
            circle.wantsLayer = true
            circle.layer?.cornerRadius = size / 2
            circle.layer?.backgroundColor = dot.cgColor
            addSubview(circle)
            // Nudge the title clear of its dot.
            button.title = "     " + title
        }

        // Right click to delete, which keeps the row clean and avoids a close
        // button on every tab that you would hit by accident.
        if let id {
            let menu = NSMenu()
            let rename = NSMenuItem(title: "Rename...",
                                    action: #selector(renameBoard(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = id.uuidString
            menu.addItem(rename)
            let delete = NSMenuItem(title: "Delete \"\(title)\"",
                                    action: #selector(deleteBoard(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = id.uuidString
            menu.addItem(delete)
            button.menu = menu
        }
        return x + width + 6
    }

    @objc private func select(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        onSelect?(raw.isEmpty ? nil : UUID(uuidString: raw))
    }

    @objc private func create() { onCreate?() }

    @objc private func renameBoard(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        onRename?(id)
    }

    @objc private func deleteBoard(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        onDelete?(id)
    }
}
