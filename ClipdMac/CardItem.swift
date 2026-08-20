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
    var onRightClick: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }

    /// Right click and control click both open the card menu.
    ///
    /// Handled here rather than by setting `menu` on the view, because the menu
    /// contents depend on which card was hit and on the current boards, so it
    /// has to be built at click time.
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
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

    /// The footer label in its two shapes. A character count is short and sits
    /// next to the index; an address is long and claims every point up to it.
    private static let countFrame = NSRect(x: 12, y: 10, width: 150, height: 16)
    private static let addressFrame = NSRect(x: 12, y: 10,
                                             width: size.width - 12 - 52, height: 16)

    /// The body area, and how a link card divides it.
    ///
    /// A link with a picture gets `linkImageFrame` for the picture and
    /// `linkTitleFrame` underneath for the page title. A link without one
    /// centres the compass in whatever is left after the title, which is why
    /// the glyph frame is computed rather than fixed.
    private static let bodyFrame = NSRect(x: 12, y: 34, width: size.width - 24,
                                          height: size.height - 58 - 44)
    private static let linkTitleFrame = NSRect(x: 12, y: 34, width: size.width - 24, height: 34)
    private static let linkImageFrame = NSRect(x: 12, y: 72, width: size.width - 24, height: 128)
    private static let glyphSize: CGFloat = 56

    /// The compass, centred in whatever the title has not taken.
    private static func glyphFrame(withTitle: Bool) -> NSRect {
        let top = bodyFrame.maxY
        let bottom = withTitle ? linkTitleFrame.maxY + 4 : bodyFrame.minY
        return NSRect(x: (size.width - glyphSize) / 2,
                      y: bottom + (top - bottom - glyphSize) / 2,
                      width: glyphSize, height: glyphSize)
    }

    private var header: NSView!
    private var kindLabel: NSTextField!
    private var timeLabel: NSTextField!
    private var iconView: NSImageView!
    private var bodyLabel: NSTextField!
    private var previewImageView: NSImageView!
    private var linkGlyph: NSImageView!
    private var linkTitle: NSTextField!
    private var countLabel: NSTextField!
    private var indexLabel: NSTextField!
    private var card: NSView!

    /// The prose look of the body label, kept here because a code card
    /// overwrites both and a recycled cell has to be put back exactly.
    private static let proseFont = NSFont.systemFont(ofSize: 12)
    private static let proseColor = NSColor(calibratedWhite: 0.92, alpha: 1)

    /// How many lines of prose the body can hold, worked out from the font
    /// rather than guessed.
    ///
    /// It was 8, which is roughly two thirds of what fits. A long paste
    /// therefore stopped in mid air with a third of the card left blank, which
    /// reads as the card being broken rather than the text being longer than
    /// the card. Deriving it means a change to the font size or the card height
    /// cannot silently reintroduce that gap.
    private static let proseLines: Int = {
        let lineHeight = ceil(proseFont.ascender - proseFont.descender + proseFont.leading)
        return max(1, Int(bodyFrame.height / lineHeight))
    }()

    /// How much of the text is handed to the preview builder.
    ///
    /// A card shows at most 12 lines, so normalising and dedenting a 3 MB paste
    /// in full would be wasted work on every scroll. 4000 characters is far
    /// more than 12 lines of anything.
    private static let codeScanLimit = 4000

    /// How much text the prose body asks for.
    ///
    /// Comfortably more than `proseLines` can show at this width, so the label
    /// runs out of room before the string runs out of characters. That is the
    /// right way round: an ellipsis means "there is more", and a card that
    /// simply stopped would mean nothing.
    private static let proseBodyLimit = 700

    private var itemKind: ItemKind = .text
    /// The colours of every board this item is filed on, in board order.
    private var boardColors: [String] = []
    private var boardDots: [NSView] = []
    private var index: Int = 0

    /// Called with (index, clickCount). One click selects, two activates.
    var onClick: ((Int, Int) -> Void)?
    /// Called with (index, event) on a right or control click.
    var onRightClick: ((Int, NSEvent) -> Void)?

    override func loadView() {
        let root = CardRootView(frame: NSRect(origin: .zero, size: CardItem.size))
        root.wantsLayer = true
        root.onClick = { [weak self] count in
            guard let self else { return }
            self.onClick?(self.index, count)
        }
        root.onRightClick = { [weak self] event in
            guard let self else { return }
            self.onRightClick?(self.index, event)
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
        bodyLabel.font = CardItem.proseFont
        bodyLabel.textColor = CardItem.proseColor
        bodyLabel.maximumNumberOfLines = CardItem.proseLines
        // Wrap, then truncate the last line. Rejected: .byTruncatingTail here,
        // which collapsed the whole label to a single truncated line even with
        // maximumNumberOfLines above 1.
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.isScrollable = false
        bodyLabel.cell?.truncatesLastVisibleLine = true
        bodyLabel.isSelectable = false
        card.addSubview(bodyLabel)

        // Image preview, shown in place of the body text for image items.
        previewImageView = NSImageView(frame: bodyLabel.frame)
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignTop
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 4
        previewImageView.layer?.masksToBounds = true
        previewImageView.isHidden = true
        card.addSubview(previewImageView)

        // The placeholder for a link with no picture: a compass, centred in the
        // body. It says "this is somewhere on the web" without pretending to
        // know anything about the page, which is exactly what we know when
        // nothing has been fetched.
        linkGlyph = NSImageView(frame: CardItem.glyphFrame(withTitle: false))
        linkGlyph.image = NSImage(systemSymbolName: "safari",
                                  accessibilityDescription: "Link")
        linkGlyph.contentTintColor = NSColor(calibratedWhite: 1, alpha: 0.28)
        linkGlyph.imageScaling = .scaleProportionallyUpOrDown
        linkGlyph.isHidden = true
        card.addSubview(linkGlyph)

        // The page's own title, under its picture. Two lines, because real
        // titles are long and one line truncates almost all of them.
        linkTitle = NSTextField(wrappingLabelWithString: "")
        linkTitle.frame = CardItem.linkTitleFrame
        linkTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        linkTitle.textColor = .white
        linkTitle.maximumNumberOfLines = 2
        linkTitle.lineBreakMode = .byWordWrapping
        linkTitle.cell?.wraps = true
        linkTitle.cell?.truncatesLastVisibleLine = true
        linkTitle.isHidden = true
        card.addSubview(linkTitle)

        // Footer: character count and position.
        countLabel = NSTextField(labelWithString: "")
        countLabel.frame = CardItem.countFrame
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byTruncatingTail
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

    func configure(with item: HistoryItem, index: Int, boardColors: [String] = [],
                   preview: LinkPreviewEntry? = nil) {
        self.index = index
        self.boardColors = boardColors
        itemKind = item.kind
        let kindName: String
        switch item.kind {
        case .link:  kindName = "Link"
        case .image: kindName = "Image"
        // "Swift" or "YAML" instead of "Text" when we know. The header is the
        // only place with room to say it, and it doubles as a check on the
        // detector: if a card says JSON over an email, the rules are wrong.
        case .text:  kindName = item.codeLanguage?.displayName ?? "Text"
        }
        // A named item leads with its name, because that is what the user chose
        // to call it. The kind drops down to join the age, so nothing is lost.
        // Rejected: a third line for the title, which would cost every card
        // eighteen points of body height to serve the few that are named.
        if let title = item.title {
            kindLabel.stringValue = title
            timeLabel.stringValue = "\(kindName) \u{00B7} \(CardItem.age(of: item.createdAt))"
        } else {
            kindLabel.stringValue = kindName
            timeLabel.stringValue = CardItem.age(of: item.createdAt)
        }
        iconView.image = AppIconCache.icon(forBundleID: item.sourceBundleID)
        // Every branch below must set all four of previewImageView, linkGlyph,
        // bodyLabel and the footer, because cells are recycled. Leaving one
        // alone is how a link's compass ends up floating over the next card's
        // paragraph.
        if item.kind == .image, let data = item.imageData {
            // Decoding a 2.8 MB PNG per visible card is fine: only a handful
            // are on screen and the collection view recycles them.
            previewImageView.image = NSImage(data: data)
            previewImageView.isHidden = false
            previewImageView.frame = CardItem.bodyFrame
            linkGlyph.isHidden = true
            linkTitle.isHidden = true
            bodyLabel.isHidden = true
            // Dimensions rather than a character count, matching the reference.
            showFooter("\(item.pixelWidth ?? 0) x \(item.pixelHeight ?? 0)", asAddress: false)
        } else if item.kind == .link {
            showLink(item, preview: preview)
        } else {
            previewImageView.image = nil
            previewImageView.isHidden = true
            linkGlyph.isHidden = true
            linkTitle.isHidden = true
            bodyLabel.isHidden = false
            if let language = item.codeLanguage {
                showCode(item.text, as: language)
            } else {
                // From `text`, not `preview`, for the same reason showCode is.
                // `preview` is the stored search string and stops at 200
                // characters, which is about eight lines here, so a long paste
                // stopped two thirds of the way down the card with no way to
                // tell that from the paste simply ending there.
                showProse(flattenedBody(item.text, limit: CardItem.proseBodyLimit))
            }
            showFooter("\(item.text.count) characters", asAddress: false)
        }
        // The number is a keyboard shortcut, not a position. Only 1 to 9 can be
        // typed as Cmd+digit, so showing 10 and up would advertise a shortcut
        // that does not exist.
        indexLabel.stringValue = index < 9 ? "\(index + 1)" : ""
        rebuildBoardDots()
        applySelection()
    }

    /// A link card: the address always, the page's picture and title when we
    /// have them.
    ///
    /// The compass is not an error state. It is what the card looks like before
    /// anything has been fetched, when fetching is switched off, and when the
    /// page turned out to have no picture to give. All three are the same thing
    /// from the card's point of view: this is a link, and that is all we know.
    private func showLink(_ item: HistoryItem, preview: LinkPreviewEntry?) {
        bodyLabel.isHidden = true
        let title = preview?.title
        linkTitle.isHidden = title == nil
        linkTitle.stringValue = title ?? ""

        if let image = preview?.image {
            previewImageView.image = image
            previewImageView.frame = title == nil ? CardItem.bodyFrame : CardItem.linkImageFrame
            previewImageView.isHidden = false
            linkGlyph.isHidden = true
        } else {
            previewImageView.image = nil
            previewImageView.isHidden = true
            linkGlyph.frame = CardItem.glyphFrame(withTitle: title != nil)
            linkGlyph.isHidden = false
        }
        showFooter(shortLinkLabel(item.text), asAddress: true)
    }

    /// The footer, in whichever of its two shapes this card needs.
    ///
    /// One function rather than three copies of the same three lines, because
    /// the frame and the alignment have to be put back on a recycled cell and a
    /// branch that forgot one would leave an address right-aligned into the
    /// middle of the card.
    private func showFooter(_ text: String, asAddress: Bool) {
        countLabel.stringValue = text
        countLabel.frame = asAddress ? CardItem.addressFrame : CardItem.countFrame
        countLabel.alignment = asAddress ? .left : .right
    }

    /// The code body: real newlines, real indentation, monospaced, coloured.
    ///
    /// Built from `text` rather than `preview`. `preview` is the flattened
    /// single line string that is persisted and searched, and reshaping it here
    /// would mean changing a stored column and migrating the database for
    /// nothing, because the full text is already on the item.
    private func showCode(_ text: String, as language: CodeLanguage) {
        let source = makeCodePreview(String(text.prefix(CardItem.codeScanLimit)),
                                     maxLines: CodeStyle.maximumLines)
        bodyLabel.maximumNumberOfLines = CodeStyle.maximumLines
        bodyLabel.lineBreakMode = CodeStyle.lineBreak
        bodyLabel.attributedStringValue =
            CodeStyle.attributedString(for: highlight(source, as: language))
    }

    /// The ordinary body, and the reset path for a recycled cell.
    ///
    /// Cells are reused, so every property `showCode` touches has to be put
    /// back here. Without this, scrolling past one JSON card leaves the next
    /// email rendered in pink monospace, which is the classic recycling bug.
    private func showProse(_ preview: String) {
        bodyLabel.font = CardItem.proseFont
        bodyLabel.textColor = CardItem.proseColor
        bodyLabel.maximumNumberOfLines = CardItem.proseLines
        bodyLabel.lineBreakMode = .byWordWrapping
        // Assigning stringValue clears any attributed string that a previous
        // code card left behind, which is why the font and colour above are set
        // first: they are what the label falls back to.
        bodyLabel.stringValue = preview
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    /// A dot per board beyond the first, so an item on three boards says so.
    ///
    /// The first board's colour is the header itself, so it needs no dot.
    private func rebuildBoardDots() {
        boardDots.forEach { $0.removeFromSuperview() }
        boardDots = []
        guard boardColors.count > 1 else { return }
        var x = CardItem.size.width - 62
        for name in boardColors.dropFirst().prefix(3) {
            let size: CGFloat = 8
            let dot = NSView(frame: NSRect(x: x, y: 8, width: size, height: size))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = size / 2
            dot.layer?.backgroundColor = BoardTabsView.color(named: name).cgColor
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = NSColor(calibratedWhite: 0, alpha: 0.25).cgColor
            header.addSubview(dot)
            boardDots.append(dot)
            x -= size + 4
        }
    }

    private func applySelection() {
        guard card != nil else { return }
        let blue = NSColor.controlAccentColor
        let neutral = NSColor(calibratedWhite: 0.22, alpha: 1)

        // A pinned card wears its board's colour, so you can see what is filed
        // where without switching tabs. Nothing else changes the header.
        //
        // Selection used to repaint the header blue as well as draw the border.
        // Two signals for one state, and on a pinned card only one of them
        // could show, so the same keypress looked different depending on
        // whether the card was filed. The border is now the only selection
        // signal, which also leaves the header free to mean one thing: which
        // board this is on.
        let boardColor = boardColors.first.map { BoardTabsView.color(named: $0) }
        header.layer?.backgroundColor = (boardColor ?? neutral).cgColor

        // The body gets a faint wash of the same colour rather than the full
        // shade. A fully coloured body would make the text on it hard to read,
        // which is the whole point of the card.
        let base = NSColor(calibratedWhite: 0.13, alpha: 1)
        card.layer?.backgroundColor = (boardColor?.withAlphaComponent(0.14) ?? base).cgColor

        // The whole selection signal. 3pt reads at a glance from a metre away,
        // which is the distance you actually sit at while arrowing through the
        // strip. Measured against 2pt, which disappeared against the dark
        // background on a pinned card.
        card.layer?.borderColor = isSelected ? blue.cgColor : NSColor.clear.cgColor
        card.layer?.borderWidth = isSelected ? 3 : 0
    }
}
