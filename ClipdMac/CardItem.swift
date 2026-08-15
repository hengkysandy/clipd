import AppKit
import ClipdCore

/// Resolves and caches source app icons.
///
/// Looking an icon up per cell per reload would hit the filesystem while
/// scrolling. The cache is tiny: one entry per app you have ever copied from.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID id: String?) -> NSImage? {
        guard let id else { return nil }
        if let hit = cache[id] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = image
        return image
    }
}

@MainActor
private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
}()

/// Reports clicks with their count.
///
/// Rejected: an NSClickGestureRecognizer on the collection view. Measured: it
/// never fired at all, because NSCollectionView consumes mouse events before
/// gesture recognizers attached to it. Handling mouseDown on the card itself
/// works and also makes selection deterministic rather than dependent on the
/// collection view's internal hit testing.
private final class CardRootView: NSView {
    var onClick: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }
}

/// One clipboard card: header, body, footer.
///
/// Built in code rather than a nib. Rejected: a xib, because XcodeGen would
/// have to carry a resources block for one view and the layout is 40 lines.
final class CardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CardItem")
    /// Height must be no larger than PanelController.scrollHeight, or the card
    /// footers clip against the bottom screen edge. Measured: at 290 in a
    /// 258pt scroll area, the character count fell off the screen.
    static let size = NSSize(width: 250, height: 268)

    private var header: NSView!
    private var kindLabel: NSTextField!
    private var timeLabel: NSTextField!
    private var iconView: NSImageView!
    private var bodyLabel: NSTextField!
    private var countLabel: NSTextField!
    private var indexLabel: NSTextField!
    private var card: NSView!

    private var itemKind: ItemKind = .text
    private var index: Int = 0

    /// Called with (index, clickCount). One click selects, two activates.
    var onClick: ((Int, Int) -> Void)?

    override func loadView() {
        let root = CardRootView(frame: NSRect(origin: .zero, size: CardItem.size))
        root.wantsLayer = true
        root.onClick = { [weak self] count in
            guard let self else { return }
            self.onClick?(self.index, count)
        }

        card = NSView(frame: root.bounds)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        card.layer?.borderWidth = 2
        card.layer?.borderColor = NSColor.clear.cgColor
        root.addSubview(card)

        // Header: kind and relative time on the left, source app icon on the right.
        header = NSView(frame: NSRect(x: 0, y: CardItem.size.height - 58,
                                      width: CardItem.size.width, height: 58))
        header.wantsLayer = true
        card.addSubview(header)

        kindLabel = NSTextField(labelWithString: "Text")
        kindLabel.frame = NSRect(x: 12, y: 30, width: 140, height: 18)
        kindLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        kindLabel.textColor = .white
        header.addSubview(kindLabel)

        timeLabel = NSTextField(labelWithString: "")
        timeLabel.frame = NSRect(x: 12, y: 10, width: 160, height: 16)
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.75)
        header.addSubview(timeLabel)

        iconView = NSImageView(frame: NSRect(x: CardItem.size.width - 52, y: 8, width: 42, height: 42))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        header.addSubview(iconView)

        // Body: the preview.
        bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.frame = NSRect(x: 12, y: 34, width: CardItem.size.width - 24,
                                 height: CardItem.size.height - 58 - 44)
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        bodyLabel.maximumNumberOfLines = 8
        // Wrap, then truncate the last line. Rejected: .byTruncatingTail here,
        // which collapsed the whole label to a single truncated line even with
        // maximumNumberOfLines above 1.
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.isScrollable = false
        bodyLabel.cell?.truncatesLastVisibleLine = true
        bodyLabel.isSelectable = false
        card.addSubview(bodyLabel)

        // Footer: character count and position.
        countLabel = NSTextField(labelWithString: "")
        countLabel.frame = NSRect(x: 12, y: 10, width: 150, height: 16)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        countLabel.alignment = .right
        card.addSubview(countLabel)

        indexLabel = NSTextField(labelWithString: "")
        indexLabel.frame = NSRect(x: CardItem.size.width - 46, y: 10, width: 34, height: 16)
        indexLabel.font = .systemFont(ofSize: 11)
        indexLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        indexLabel.alignment = .right
        card.addSubview(indexLabel)

        view = root
    }

    /// Relative age, with the fresh case special cased.
    ///
    /// RelativeDateTimeFormatter rounds an age under a second to zero and then
    /// guesses a direction, producing "in 0 seconds" in future tense on the
    /// item you copied a moment ago. That reads as a bug to anyone who sees it.
    static func age(of date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 5 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    func configure(with item: HistoryItem, index: Int) {
        self.index = index
        itemKind = item.kind
        kindLabel.stringValue = item.kind == .link ? "Link" : "Text"
        timeLabel.stringValue = CardItem.age(of: item.createdAt)
        iconView.image = AppIconCache.icon(forBundleID: item.sourceBundleID)
        bodyLabel.stringValue = item.preview
        countLabel.stringValue = "\(item.text.count) characters"
        indexLabel.stringValue = "\(index + 1)"
        applySelection()
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    private func applySelection() {
        guard card != nil else { return }
        // Link headers are blue, text headers are neutral, and the selected
        // card is blue whatever its kind. This matches the reference app:
        // in its screenshot a selected Text card and an unselected Link card
        // are both blue, and unselected Text cards are grey.
        let blue = NSColor.controlAccentColor
        let neutral = NSColor(calibratedWhite: 0.22, alpha: 1)
        header.layer?.backgroundColor = (isSelected || itemKind == .link)
            ? blue.cgColor : neutral.cgColor
        card.layer?.borderColor = isSelected ? blue.cgColor : NSColor.clear.cgColor
    }
}
