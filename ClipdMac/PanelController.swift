import AppKit
import ClipdCore

/// A borderless panel refuses to become key by default, and the search field
/// then silently receives nothing at all. This override is not optional.
private final class ClipdPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Cmd+1 to Cmd+9 files the selected card on that board.
    ///
    /// Rejected: drag and drop, slower than a keystroke for the case this app
    /// is for. Rejected: a context menu, which needs the mouse.
    var onNumberKey: ((Int) -> Bool)?
    /// Cmd+Left and Cmd+Right move between boards. Plain arrows already move
    /// between cards, so the modifier is what separates the two axes.
    var onBoardStep: ((Int) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if let characters = event.charactersIgnoringModifiers,
           let digit = Int(characters), digit >= 1, digit <= 9,
           onNumberKey?(digit) == true {
            return true
        }
        // 123 is left arrow, 124 is right arrow.
        if event.keyCode == 123, onBoardStep?(-1) == true { return true }
        if event.keyCode == 124, onBoardStep?(1) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Refuses first responder so a click on a card never takes focus away from
/// the search field.
///
/// Without this, clicking a card moved first responder to the collection view,
/// and every keyboard shortcut silently stopped working: Escape did nothing
/// until you clicked back into the search field. Keeping one first responder
/// means one place handles keys, which is also how Spotlight behaves.
private final class NonFocusingCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSTextFieldDelegate,
                             NSCollectionViewDataSource, NSCollectionViewDelegate {

    // These three must stay consistent or the cards clip against the bottom
    // screen edge. The scroll area is panelHeight - topBarHeight - 32, and
    // CardItem.size.height must be no larger than that. Measured the hard way:
    // at 330 and 290 the card footers fell off the screen.
    private static let panelHeight: CGFloat = 360
    private static let topBarHeight: CGFloat = 52
    private static var scrollHeight: CGFloat { panelHeight - topBarHeight - 32 }

    /// The bottom edge of the top bar. Every control in the bar is placed
    /// against it. It was a local in buildTopBar, and is shared now only
    /// because the controls are built in one place and added in another.
    private static var barY: CGFloat { panelHeight - topBarHeight }

    private let history: History

    // The seven views below are plain `let`, built before super.init.
    //
    // They used to be `var x: T!`. That exact shape has already crashed this
    // app once: the app delegate held its collaborators as `!`, a sweep running
    // during launch called back into one that had not been created yet, and the
    // app died on launch for anyone whose history had duplicates. Nothing here
    // reads a view before build() fills it in today, but one reordered line
    // inside build() would be the same crash, and the compiler would say
    // nothing either time.
    //
    // As `let` the compiler proves each one non-nil, so the order inside
    // build() stops being load bearing.
    //
    // Rejected: `lazy var x = makeX()`. It also proves non-nil, but it carries
    // its own trap: a callback that fires while a lazy property is still
    // running its initialiser re-enters that property. It is not needed here,
    // because nothing needs `self` at construction time. Every reference to
    // self (the field delegate, the collection data source and delegate, the
    // tab closures, the panel key handlers) is a property set on an
    // already-built view, so all of that wiring stays in build() where it was.
    //
    // Rejected: `var x: T?` plus a force unwrap at each use. That is the same
    // crash spread over more lines. Rejected too: `guard let` in the view code,
    // which would open the panel with no search field and log nothing, which is
    // worse than a crash because nobody would ever hear about it.
    private let panel: ClipdPanel
    private let field: NSTextField
    private let banner: NSTextField
    private let collection: NSCollectionView
    private let scroll: NSScrollView
    private let emptyLabel: NSTextField
    private let tabs: BoardTabsView

    /// The width the views were built at. show() resizes the panel to the real
    /// screen on every open, so this is only a starting size.
    private let initialWidth: CGFloat

    private var results: [HistoryItem] = []
    private var selection: Int = 0
    private var isDismissing = false
    /// True while one of our own dialogs is up.
    ///
    /// A modal alert takes key focus, which fires the resign-key handler and
    /// dismissed the panel underneath it. The New Pinboard dialog then typed
    /// into whatever app was behind. Click-away must still close the panel, so
    /// the flag is narrower than disabling the handler.
    private var isPresentingModal = false
    private var boards: [Pinboard] = []
    private var membership: [UUID: Set<UUID>] = [:]
    private var selectedBoard: UUID?

    /// Supplied by the app, so the panel never talks to the database directly.
    var boardProvider: () -> ([Pinboard], [UUID: Set<UUID>]) = { ([], [:]) }
    var onCreateBoard: ((String) -> Void)?
    var onDeleteBoard: ((UUID) -> Void)?
    var onRenameBoard: ((UUID, String) -> Void)?
    var onToggleMembership: ((UUID, UUID) -> Void)?

    /// Full text search across the whole stored history, not just what the panel
    /// holds in memory. Nil until the app wires it, and nil is safe: the panel
    /// then behaves exactly as it did before, searching the loaded items.
    var searchProvider: ((String) -> [HistoryItem])?

    /// The app that was frontmost when the panel opened. Everything depends on
    /// putting it back before pasting.
    private(set) var previousApp: NSRunningApplication?

    var onCommit: ((HistoryItem, NSRunningApplication?) -> Void)?

    init(history: History) {
        self.history = history
        // Read the screen once and build every frame from that one number.
        // Reading it per view could hand out two different widths if a display
        // is attached or removed between the calls.
        let width = PanelController.startingWidth()
        initialWidth = width
        // Creation order is the same order build() used to create them in, so
        // the frames and the sizes are unchanged. It is no longer load bearing
        // for safety, only for reading: scroll needs collection, and emptyLabel
        // is centred on scroll's frame.
        panel = PanelController.makePanel(width: width)
        field = PanelController.makeField()
        tabs = PanelController.makeTabs(width: width)
        banner = PanelController.makeBanner(width: width)
        collection = PanelController.makeCollection()
        scroll = PanelController.makeScroll(width: width, document: collection)
        emptyLabel = PanelController.makeEmptyLabel(width: width,
                                                    centeredOn: scroll.frame)
        super.init()
        build()
    }

    // MARK: - View makers
    //
    // These are static on purpose. A static function cannot touch `self`, so
    // the compiler enforces that nothing here can call back into a
    // half-built controller. Everything that does need self stays in build().

    /// The width to build at.
    ///
    /// NSScreen.main is nil when the machine has no display awake, which is a
    /// real state for a menu bar app that starts at login. 1440 is the number
    /// this code has always fallen back to, so it stays. A wrong guess costs
    /// nothing visible: show() calls onscreenFrame() and resizes the panel to
    /// the real screen before it is ever seen, and the subviews that care about
    /// width (the banner and the empty label) are only ever shown after that.
    ///
    /// Rejected: refusing to build the panel when there is no screen. That
    /// needs the views back as optionals, which is the shape being removed.
    private static func startingWidth() -> CGFloat {
        NSScreen.main?.frame.width ?? 1440
    }

    private static func makePanel(width: CGFloat) -> ClipdPanel {
        let rect = NSRect(x: 0, y: 0, width: width, height: panelHeight)
        let panel = ClipdPanel(contentRect: rect,
                               styleMask: [.nonactivatingPanel, .borderless],
                               backing: .buffered, defer: false)
        // .screenSaver so it appears above a fullscreen app and above the Dock.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        return panel
    }

    private static func makeField() -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 50, y: barY + 12,
                                              width: 420, height: 26))
        field.placeholderString = "Search clipboard history"
        field.font = .systemFont(ofSize: 14)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = .white
        return field
    }

    private static func makeTabs(width: CGFloat) -> BoardTabsView {
        BoardTabsView(frame: NSRect(x: 490, y: barY + 11,
                                    width: max(width - 520, 200), height: 30))
    }

    /// The loud failure. Without Accessibility, macOS discards every
    /// synthesised event and reports nothing, so the app would otherwise look
    /// perfectly healthy while pasting nothing.
    private static func makeBanner(width: CGFloat) -> NSTextField {
        let banner = NSTextField(labelWithString: "")
        banner.frame = NSRect(x: 22, y: barY + 10, width: width - 44, height: 30)
        banner.font = .boldSystemFont(ofSize: 13)
        banner.textColor = .white
        banner.backgroundColor = .systemOrange
        banner.drawsBackground = true
        banner.alignment = .center
        banner.isHidden = true
        return banner
    }

    private static func makeCollection() -> NSCollectionView {
        let layout = NSCollectionViewFlowLayout()
        // Horizontal, so the history reads as a strip you scroll sideways.
        layout.scrollDirection = .horizontal
        layout.itemSize = CardItem.size
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)

        let collection = NonFocusingCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        // Rejected: an NSStackView of cards. Simpler, but it builds every card
        // up front and the history holds up to 500, which stutters. The
        // collection view recycles.
        //
        // The registration happens here, at construction, so it is done before
        // the data source is attached in buildCollection and long before any
        // reload. makeItem with an unregistered identifier throws.
        collection.register(CardItem.self,
                            forItemWithIdentifier: CardItem.identifier)
        return collection
    }

    private static func makeScroll(width: CGFloat,
                                   document: NSCollectionView) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 16, width: width,
                                                height: scrollHeight))
        scroll.documentView = document
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    /// An empty panel with nothing in it reads as broken. Say which of the
    /// three empty cases it is, because they need different actions from the
    /// user.
    private static func makeEmptyLabel(width: CGFloat,
                                       centeredOn scrollFrame: NSRect) -> NSTextField {
        let emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.frame = NSRect(x: 0, y: scrollFrame.midY - 20,
                                  width: width, height: 40)
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        return emptyLabel
    }

    // MARK: - Build

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: initialWidth, height: Self.panelHeight)

        // A blurred material, not flat translucency. Rejected: a plain layer
        // background at 0.96 alpha, which let whatever was behind the panel
        // show through as legible text and made the cards hard to read.
        let content = NSVisualEffectView(frame: rect)
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        // Only the top corners. The panel sits flush on the bottom screen edge,
        // so rounding the bottom would show a sliver of desktop under it.
        content.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        buildTopBar(in: content)
        buildCollection(in: content)

        panel.contentView = content

        // Click anywhere outside and the panel goes away. Losing key status is
        // the signal: it covers clicking another app, clicking the desktop and
        // switching apps with Cmd+Tab, which a click monitor would not.
        panel.onNumberKey = { [weak self] digit in
            guard let self, digit <= self.boards.count,
                  self.selection >= 0, self.selection < self.results.count else { return false }
            let board = self.boards[digit - 1]
            let item = self.results[self.selection]
            self.onToggleMembership?(item.id, board.id)
            (self.boards, self.membership) = self.boardProvider()
            self.reload()
            return true
        }

        panel.onBoardStep = { [weak self] step in
            guard let self, !self.boards.isEmpty else { return false }
            // Clipboard sits at index 0, so the list is boards.count + 1 wide
            // and wraps at both ends.
            let current = self.selectedBoard.flatMap { id in
                self.boards.firstIndex { $0.id == id }.map { $0 + 1 }
            } ?? 0
            let count = self.boards.count + 1
            let next = ((current + step) % count + count) % count
            self.selectedBoard = next == 0 ? nil : self.boards[next - 1].id
            self.refreshTabs()
            self.reload()
            return true
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey),
            name: NSWindow.didResignKeyNotification, object: panel)
    }

    @objc private func panelResignedKey() {
        // The guard matters. Committing a paste orders the panel out and
        // activates the previous app, which itself resigns key. Without this
        // the dismiss animation would run a second time on top of itself.
        guard panel.isVisible, !isDismissing, !isPresentingModal else { return }
        dismiss()
    }

    /// Adds the top bar views and does the wiring that needs `self`. The views
    /// themselves are already built, see the makers above.
    private func buildTopBar(in content: NSVisualEffectView) {
        // The magnifying glass is the one view here that is not a stored
        // property. It is decoration, nothing ever reads it again, so it stays
        // a local.
        let glass = NSImageView(frame: NSRect(x: 22, y: Self.barY + 16,
                                              width: 18, height: 18))
        glass.image = NSImage(systemSymbolName: "magnifyingglass",
                              accessibilityDescription: "Search")
        glass.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        content.addSubview(glass)

        field.delegate = self
        content.addSubview(field)

        tabs.onSelect = { [weak self] id in
            self?.selectedBoard = id
            self?.refreshTabs()
            self?.reload()
        }
        tabs.onCreate = { [weak self] in self?.promptForNewBoard() }
        tabs.onDelete = { [weak self] id in self?.confirmDeleteBoard(id) }
        tabs.onRename = { [weak self] id in self?.promptToRenameBoard(id) }
        content.addSubview(tabs)

        content.addSubview(banner)
    }

    /// Adds the card strip and does the wiring that needs `self`.
    private func buildCollection(in content: NSVisualEffectView) {
        // The item class was registered in makeCollection, so the data source
        // can never be asked for a cell it has no registration for.
        collection.dataSource = self
        collection.delegate = self

        content.addSubview(scroll)
        content.addSubview(emptyLabel)
    }

    /// One click selects, two pastes. Clicks arrive from the card itself, not
    /// from a gesture recognizer, which never fired.
    private func handleCardClick(index: Int, clickCount: Int) {
        Diag.panel.debug("card click index \(index, privacy: .public) clicks \(clickCount, privacy: .public)")
        guard index >= 0, index < results.count else { return }
        selection = index
        applySelection(scroll: false)
        if clickCount >= 2 { commitSelection() }
    }

    // MARK: - Show and hide

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { dismiss(); return }
        show()
    }

    private func onscreenFrame() -> NSRect {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Flush to the bottom edge of the screen, full width.
        return NSRect(x: screen.minX, y: screen.minY,
                      width: screen.width, height: Self.panelHeight)
    }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        field.stringValue = ""
        (boards, membership) = boardProvider()
        if let current = selectedBoard, !boards.contains(where: { $0.id == current }) {
            // Deleted on the other Mac. Fall back to everything rather than
            // showing an empty panel with no explanation.
            selectedBoard = nil
        }
        refreshTabs()
        reload()
        updateTrustBanner()

        let target = onscreenFrame()
        // Start below the screen edge and slide up.
        var start = target
        start.origin.y = target.minY - Self.panelHeight
        panel.setFrame(start, display: false)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        // NEVER read panel.isKeyWindow here. Activation is asynchronous and
        // measures false in this same runloop turn, which looks exactly like a
        // hard failure. It becomes true within 10ms.

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }

        Diag.panel.info("opened, previous app \(self.previousApp?.bundleIdentifier ?? "nil", privacy: .public), \(self.results.count, privacy: .public) results, accessibilityTrusted \(AXIsProcessTrusted(), privacy: .public)")
    }

    func dismiss() { hide(then: nil) }

    /// Slides down, then runs `then`. The paste must happen AFTER the panel is
    /// gone and focus is restored, so the completion is not optional politeness.
    private func hide(then: (() -> Void)?) {
        guard !isDismissing else { return }
        isDismissing = true
        var target = panel.frame
        target.origin.y = onscreenFrame().minY - Self.panelHeight
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.field.stringValue = ""
            self.previousApp?.activate()
            self.isDismissing = false
            then?()
        })
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

    // MARK: - Data

    private func updateEmptyState(board: Pinboard?) {
        emptyLabel.isHidden = !results.isEmpty
        guard results.isEmpty else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            emptyLabel.stringValue = "Nothing matches \"\(query)\"."
        } else if let board {
            emptyLabel.stringValue = "Nothing pinned to \(board.name) yet. "
                + "Select a card on Clipboard, then right click and choose Pin."
        } else {
            emptyLabel.stringValue = "Nothing copied yet. Copy something and it appears here."
        }
    }

    private func refreshTabs() {
        tabs.update(boards: boards, selected: selectedBoard)
    }

    /// The items to show before the board filter is applied.
    ///
    /// An empty field means "no filter", so the in-memory timeline is right and
    /// costs nothing. A real query goes to the store instead, because the panel
    /// only holds the newest 500 rows: with retention on six months or a year
    /// everything older was simply not findable, and search silently pretended
    /// those items did not exist.
    ///
    /// Falls back to the in-memory scan when the store returns nothing, for two
    /// reasons. A store that cannot answer (a damaged index) should degrade to
    /// the old search rather than to an empty strip while the user is typing.
    /// And FTS5 matches whole words and prefixes only, so it cannot find a
    /// match in the MIDDLE of a word, which the substring scan can. Falling
    /// back means this change can only ever find MORE than before, never less.
    private func currentItems() -> [HistoryItem] {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let searchProvider else { return history.search(field.stringValue) }
        let hits = searchProvider(query)
        return hits.isEmpty ? history.search(field.stringValue) : hits
    }

    /// Recomputes the visible strip from the field and the selected board.
    ///
    /// One place on purpose. `commitDelete` used to rebuild `results` itself
    /// with `history.search(...)` and NO board filter, so deleting a card while
    /// a pinboard tab was selected silently replaced the strip with the whole
    /// history while the tab still rendered as selected. It also skipped the
    /// empty state, so a delete that emptied the view left no label explaining
    /// why. Two callers computing the same thing two ways is how that drifted.
    private func refreshResults() {
        let board = boards.first { $0.id == selectedBoard }
        results = itemsOn(board, items: currentItems(), membership: membership)
        collection.reloadData()
        updateEmptyState(board: board)
    }

    private func reload() {
        refreshResults()
        selection = 0
        applySelection(scroll: false)
    }

    private func applySelection(scroll shouldScroll: Bool) {
        guard !results.isEmpty else {
            collection.deselectAll(nil)
            return
        }
        let clamped = min(max(selection, 0), results.count - 1)
        selection = clamped
        let path = IndexPath(item: clamped, section: 0)
        collection.selectionIndexPaths = [path]
        if shouldScroll {
            collection.scrollToItems(at: [path], scrollPosition: .centeredHorizontally)
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
            // Clear a search first, close second. Otherwise Escape throws away
            // the panel when you only wanted to undo a typo.
            if !field.stringValue.isEmpty {
                field.stringValue = ""
                reload()
            } else {
                dismiss()
            }
            return true
        // Left and right, because the history is a horizontal strip. This does
        // cost cursor movement inside the search field, which is the accepted
        // trade for arrow keys meaning "next card".
        case #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveDown(_:)):
            selection += 1
            applySelection(scroll: true)
            return true
        case #selector(NSResponder.moveLeft(_:)),
             #selector(NSResponder.moveUp(_:)):
            selection -= 1
            applySelection(scroll: true)
            return true
        // Backspace deletes the selected card, but ONLY when the search box is
        // empty. Otherwise backspace has to keep editing the search text, or
        // correcting a typo would silently destroy history.
        case #selector(NSResponder.deleteBackward(_:)):
            guard field.stringValue.isEmpty else { return false }
            deleteSelected()
            return true
        // Forward delete always deletes the card, since it never edits
        // backwards over what you just typed.
        case #selector(NSResponder.deleteForward(_:)):
            deleteSelected()
            return true
        default:
            return false
        }
    }

    private func deleteSelected() {
        guard selection >= 0, selection < results.count else { return }
        let doomed = results[selection]

        // Animate the card away before the data changes.
        //
        // Without this a card vanishes between two frames and the ones to its
        // right jump left, which reads as a glitch rather than a deletion. The
        // motion is what tells you which card went.
        //
        // Rejected: NSCollectionView's animator().deleteItems, which needs the
        // data source mutated in the same batch and fights the reloadData the
        // filter already relies on.
        if let view = collection.item(at: IndexPath(item: selection, section: 0))?.view {
            view.wantsLayer = true
            let layer = view.layer
            let original = layer?.transform ?? CATransform3DIdentity
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 0
                // Shrink towards the card's own centre, not its corner.
                layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer?.position = CGPoint(x: view.frame.midX, y: view.frame.midY)
                layer?.transform = CATransform3DScale(original, 0.82, 0.82, 1)
            }, completionHandler: { [weak self] in
                // The cell is recycled, so put it back exactly as it was or the
                // next card to land in this slot inherits a shrunken ghost.
                view.alphaValue = 1
                layer?.transform = original
                self?.commitDelete(of: doomed)
            })
            return
        }
        commitDelete(of: doomed)
    }

    // MARK: - Card menu

    /// A small colour swatch for a board's menu entry.
    ///
    /// Built here rather than shipped as art, so a new palette colour needs no
    /// new asset.
    private func dot(_ colorName: String) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        BoardTabsView.color(named: colorName).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    /// The right click menu on a card.
    ///
    /// Built at click time because it depends on which card was hit, which app
    /// you came from, and which boards the item is already on.
    ///
    /// Deliberately omits "Paste as Plain Text" from the reference app: Clipd
    /// captures plain text only today, so that command would be byte identical
    /// to Paste, and a menu entry that does nothing is worse than none.
    private func showCardMenu(index: Int, event: NSEvent) {
        guard index >= 0, index < results.count else { return }
        selection = index
        applySelection(scroll: false)
        let item = results[index]

        let menu = NSMenu()

        let target = previousApp?.localizedName ?? "the previous app"
        let paste = NSMenuItem(title: "Paste to \(target)",
                               action: #selector(menuPaste), keyEquivalent: "\r")
        paste.keyEquivalentModifierMask = []
        paste.target = self
        menu.addItem(paste)

        let copy = NSMenuItem(title: "Copy", action: #selector(menuCopy), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)

        menu.addItem(.separator())

        // Pin, with a tick against every board this item is already on, so the
        // same menu adds and removes.
        let pin = NSMenuItem(title: "Pin", action: nil, keyEquivalent: "")
        let boardMenu = NSMenu()
        for (offset, board) in boards.enumerated() {
            let entry = NSMenuItem(title: board.name,
                                   action: #selector(menuTogglePin(_:)), keyEquivalent: "")
            entry.target = self
            entry.image = dot(board.colorName)
            entry.representedObject = board.id.uuidString
            entry.state = (membership[board.id] ?? []).contains(item.id) ? .on : .off
            // Show the shortcut that already exists, so the menu teaches it.
            if offset < 9 {
                entry.keyEquivalent = "\(offset + 1)"
                entry.keyEquivalentModifierMask = .command
            }
            boardMenu.addItem(entry)
        }
        if !boards.isEmpty { boardMenu.addItem(.separator()) }
        let create = NSMenuItem(title: "Create Pinboard...",
                                action: #selector(menuCreateBoard), keyEquivalent: "")
        create.target = self
        boardMenu.addItem(create)
        pin.submenu = boardMenu
        menu.addItem(pin)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete", action: #selector(menuDelete),
                                keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!))
        delete.keyEquivalentModifierMask = []
        delete.target = self
        menu.addItem(delete)

        // The menu takes key focus, which would otherwise fire the click-away
        // dismissal and close the panel out from under it.
        isPresentingModal = true
        NSMenu.popUpContextMenu(menu, with: event, for: collection)
        isPresentingModal = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    @objc private func menuPaste() { commitSelection() }

    /// Puts the item on the clipboard without pasting it.
    ///
    /// Rejected: doing this by pasting into a hidden field, which needs
    /// Accessibility. Copy should work even when paste cannot.
    @objc private func menuCopy() {
        guard selection >= 0, selection < results.count else { return }
        let item = results[selection]
        hide(then: {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if item.kind == .image, let data = item.imageData {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            } else {
                pasteboard.setString(item.text, forType: .string)
            }
            Diag.panel.info("copied to the clipboard without pasting")
        })
    }

    @objc private func menuDelete() { deleteSelected() }

    @objc private func menuCreateBoard() { promptForNewBoard() }

    @objc private func menuTogglePin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let boardID = UUID(uuidString: raw),
              selection >= 0, selection < results.count else { return }
        onToggleMembership?(results[selection].id, boardID)
        (boards, membership) = boardProvider()
        refreshTabs()
        reload()
    }

    private func promptForNewBoard() {
        let alert = NSAlert()
        alert.messageText = "New pinboard"
        alert.informativeText = "Give it a name."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "Work"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        isPresentingModal = true
        let response = alert.runModal()
        isPresentingModal = false
        // Put focus back on the panel, or the next keystroke goes to whatever
        // was behind it.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        guard response == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onCreateBoard?(name)
        (boards, membership) = boardProvider()
        refreshTabs()
        reload()
    }

    private func promptToRenameBoard(_ id: UUID) {
        guard let board = boards.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename pinboard"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = board.name
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        isPresentingModal = true
        let response = alert.runModal()
        isPresentingModal = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        guard response == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onRenameBoard?(id, name)
        (boards, membership) = boardProvider()
        refreshTabs()
        reload()
    }

    private func confirmDeleteBoard(_ id: UUID) {
        let name = boards.first { $0.id == id }?.name ?? "this pinboard"
        let alert = NSAlert()
        alert.messageText = "Delete \"\(name)\"?"
        // Say plainly that the items survive. Otherwise this reads as
        // "delete these clippings", which it is not.
        alert.informativeText = "The pinboard is removed. The items on it stay in your history."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        isPresentingModal = true
        let response = alert.runModal()
        isPresentingModal = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        guard response == .alertFirstButtonReturn else { return }
        onDeleteBoard?(id)
        if selectedBoard == id { selectedBoard = nil }
        (boards, membership) = boardProvider()
        refreshTabs()
        reload()
    }

    private func commitDelete(of doomed: HistoryItem) {
        let removed = history.remove(id: doomed.id)
        Diag.panel.info("deleted 1 item, \(doomed.text.count, privacy: .public) chars, removed \(removed, privacy: .public)")
        let previousSelection = selection
        refreshResults()
        // Keep the cursor where it was rather than jumping to the start, so
        // holding backspace deletes a run of items the way you would expect.
        selection = min(previousSelection, max(results.count - 1, 0))
        applySelection(scroll: true)
    }

    private func commitSelection() {
        Diag.panel.debug("commit with selection \(self.selection, privacy: .public) of \(self.results.count, privacy: .public)")
        guard selection >= 0, selection < results.count else { dismiss(); return }
        let chosen = results[selection]
        let target = previousApp
        hide(then: { [weak self] in
            self?.onCommit?(chosen, target)
        })
    }

    // MARK: - NSCollectionView

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        results.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: CardItem.identifier,
                                           for: indexPath)
        if let card = cell as? CardItem, indexPath.item < results.count {
            let item = results[indexPath.item]
            // Board order, so a card's colour is stable rather than depending
            // on dictionary iteration order.
            let colors = boards.filter { (membership[$0.id] ?? []).contains(item.id) }
                               .map(\.colorName)
            card.configure(with: item, index: indexPath.item, boardColors: colors)
            card.onClick = { [weak self] index, clicks in
                self?.handleCardClick(index: index, clickCount: clicks)
            }
            card.onRightClick = { [weak self] index, event in
                self?.showCardMenu(index: index, event: event)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let first = indexPaths.first { selection = first.item }
    }
}
