import AppKit
import ClipdCore

/// A borderless panel refuses to become key by default, and the search field
/// then silently receives nothing at all. This override is not optional.
private final class ClipdPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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

    private let history: History
    private var panel: ClipdPanel!
    private var field: NSTextField!
    private var banner: NSTextField!
    private var collection: NSCollectionView!
    private var scroll: NSScrollView!
    private var results: [HistoryItem] = []
    private var selection: Int = 0
    private var isDismissing = false

    /// The app that was frontmost when the panel opened. Everything depends on
    /// putting it back before pasting.
    private(set) var previousApp: NSRunningApplication?

    var onCommit: ((HistoryItem, NSRunningApplication?) -> Void)?

    init(history: History) {
        self.history = history
        super.init()
        build()
    }

    // MARK: - Build

    private func build() {
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let rect = NSRect(x: 0, y: 0, width: screenWidth, height: Self.panelHeight)

        panel = ClipdPanel(contentRect: rect,
                           styleMask: [.nonactivatingPanel, .borderless],
                           backing: .buffered, defer: false)
        // .screenSaver so it appears above a fullscreen app and above the Dock.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

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

        buildTopBar(in: content, width: screenWidth)
        buildCollection(in: content, width: screenWidth)

        panel.contentView = content

        // Click anywhere outside and the panel goes away. Losing key status is
        // the signal: it covers clicking another app, clicking the desktop and
        // switching apps with Cmd+Tab, which a click monitor would not.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey),
            name: NSWindow.didResignKeyNotification, object: panel)
    }

    @objc private func panelResignedKey() {
        // The guard matters. Committing a paste orders the panel out and
        // activates the previous app, which itself resigns key. Without this
        // the dismiss animation would run a second time on top of itself.
        guard panel.isVisible, !isDismissing else { return }
        dismiss()
    }

    private func buildTopBar(in content: NSVisualEffectView, width: CGFloat) {
        let barY = Self.panelHeight - Self.topBarHeight

        let glass = NSImageView(frame: NSRect(x: 22, y: barY + 16, width: 18, height: 18))
        glass.image = NSImage(systemSymbolName: "magnifyingglass",
                              accessibilityDescription: "Search")
        glass.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        content.addSubview(glass)

        field = NSTextField(frame: NSRect(x: 50, y: barY + 12, width: 420, height: 26))
        field.placeholderString = "Search clipboard history"
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = .white
        content.addSubview(field)

        // The loud failure. Without Accessibility, macOS discards every
        // synthesised event and reports nothing, so the app would otherwise
        // look perfectly healthy while pasting nothing.
        banner = NSTextField(labelWithString: "")
        banner.frame = NSRect(x: 22, y: barY + 10, width: width - 44, height: 30)
        banner.font = .boldSystemFont(ofSize: 13)
        banner.textColor = .white
        banner.backgroundColor = .systemOrange
        banner.drawsBackground = true
        banner.alignment = .center
        banner.isHidden = true
        content.addSubview(banner)
    }

    private func buildCollection(in content: NSVisualEffectView, width: CGFloat) {
        let layout = NSCollectionViewFlowLayout()
        // Horizontal, so the history reads as a strip you scroll sideways.
        layout.scrollDirection = .horizontal
        layout.itemSize = CardItem.size
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)

        collection = NonFocusingCollectionView()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        // Rejected: an NSStackView of cards. Simpler, but it builds every card
        // up front and the history holds up to 500, which stutters. The
        // collection view recycles.
        collection.register(CardItem.self,
                            forItemWithIdentifier: CardItem.identifier)

        scroll = NSScrollView(frame: NSRect(x: 0, y: 16, width: width,
                                            height: Self.scrollHeight))
        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        content.addSubview(scroll)

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

    private func reload() {
        results = history.search(field.stringValue)
        collection.reloadData()
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
            dismiss()
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

    private func commitDelete(of doomed: HistoryItem) {
        let removed = history.remove(id: doomed.id)
        Diag.panel.info("deleted 1 item, \(doomed.text.count, privacy: .public) chars, removed \(removed, privacy: .public)")
        let previousSelection = selection
        results = history.search(field.stringValue)
        collection.reloadData()
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
            card.configure(with: results[indexPath.item], index: indexPath.item)
            card.onClick = { [weak self] index, clicks in
                self?.handleCardClick(index: index, clickCount: clicks)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let first = indexPaths.first { selection = first.item }
    }
}
