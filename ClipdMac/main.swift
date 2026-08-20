import AppKit
import ClipdCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Optional, not force unwrapped.
    ///
    /// openStore() runs before the status item is built and can call
    /// rebuildMenu() through the dedup and retention sweeps. A force unwrap
    /// crashed the app on launch whenever either found work to do.
    private var statusItem: NSStatusItem?

    /// Built on first use, which is still inside applicationDidFinishLaunching.
    ///
    /// lazy, not a force unwrapped var. The compiler now proves the property is
    /// never nil, so no call site can ever crash on a watcher that does not
    /// exist yet. That is the same trap the status item fell into.
    ///
    /// Rejected: a plain optional plus guard let at every use. A nil watcher
    /// would mean capture never started, and turning that into a quiet early
    /// return hides a total failure of the app's one job.
    ///
    /// Rejected: a let assigned in init. Both callbacks capture self, and self
    /// is not available before super.init() returns, so a let cannot be formed
    /// there.
    private lazy var watcher: PasteboardWatcher = makeWatcher()

    private var hotKey: HotKey?

    /// Same shape as the watcher, for the same reason: never nil, never force
    /// unwrapped.
    ///
    /// Rejected: a let assigned in init. PanelController builds its NSPanel and
    /// reads NSScreen inside its own initialiser, and our init runs before the
    /// activation policy is set and before the run loop starts. lazy keeps that
    /// window build at exactly the point in launch where it happens today.
    private lazy var panelController: PanelController = PanelController(history: history)
    let history = History()
    private var pause = PauseState.running
    private var pauseTicker: Timer?
    private var settings = AppSettings()
    private var settingsWindow: SettingsWindowController?
    private let accessibility = AccessibilityMonitor(probe: DemoMode.accessibilityProbe)
    private var onboarding: OnboardingWindowController?
    private var retentionTimer: Timer?
    private var syncTimer: Timer?
    private var syncDebounce: Timer?
    private var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncSummary: String?
    private var database: Database?
    private var store: SQLiteStore?
    /// Built with the store, because it reads and writes the preview cache.
    private var previews: LinkPreviewCache?
    private var lastPausedFlag = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        // The status item first. openStore() runs the dedup and retention
        // sweeps, both of which rebuild the menu, so it has to exist by then.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if statusItem?.button == nil {
            // Said once here, not in setStatusIcon, which runs on every capture
            // and would repeat the same line forever. No button means macOS gave
            // us no menu bar slot, usually because the bar is full. Capture, the
            // panel and the hotkey all still work, only the icon is missing.
            Diag.capture.error("no menu bar button, the status icon will not be drawn")
        }
        openStore()
        rebuildMenu()   // sets the icon too

        // The first read of watcher is what builds it, at the same moment in
        // launch as the old assignment.
        watcher.isPaused = { [weak self] in
            self?.pause.isPaused(now: Date()) ?? false
        }
        // Rebuild capture settings whenever the user changes them, so a newly
        // ignored app takes effect on the next copy rather than after a restart.
        watcher.settingsProvider = { [weak self] in
            self?.settings.captureSettings ?? .standard
        }
        settings.onChange = { [weak self] in
            Diag.capture.info("settings changed, capture rules reloaded")
            self?.rebuildMenu()
            // Switching previews off throws away what was already fetched. The
            // setting says the app should not be holding pictures of other
            // people's pages, and that has to be true of the ones it already
            // has, not only of the next one.
            if self?.settings.linkPreviewsEnabled == false {
                self?.previews?.forgetEverything()
            }
        }
        watcher.start()

        // A timed pause expires by itself, and nothing else would redraw the
        // icon, so a resumed app would keep showing the pause glyph until the
        // next copy. Redraws only on an actual change, so it costs nothing.
        pauseTicker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let paused = self.pause.isPaused(now: Date())
                guard paused != self.lastPausedFlag else { return }
                self.lastPausedFlag = paused
                if !paused { Diag.capture.info("pause expired, resuming") }
                self.rebuildMenu()
            }
        }

        // Same again: this first read is what builds the panel, in the same
        // place in launch as the old assignment.
        panelController.boardProvider = { [weak self] in
            guard let store = self?.store else { return ([], [:]) }
            return ((try? store.allPinboards()) ?? [], (try? store.membership()) ?? [:])
        }
        // Search goes to the database, not to the 500 rows the panel happens to
        // hold. With retention on a year, everything older than those 500 was
        // unfindable, and search gave no hint that it was only looking at part
        // of the history.
        panelController.searchProvider = { [weak self] query in
            guard let store = self?.store else { return [] }
            return (try? store.search(query, limit: 500)) ?? []
        }
        // Naming an item writes the row and then reloads the in-memory history,
        // because the panel reads its cards from there. Rejected: mutating the
        // cached HistoryItem in place, which would show the new name until the
        // next launch and then lose it if the write had failed.
        panelController.onRenameItem = { [weak self] id, title in
            guard let self, let store else { return }
            do {
                try store.setTitle(title, for: id)
                history.load(try store.loadAll(limit: 500))
                Diag.panel.info("item renamed, named now \(title != nil, privacy: .public)")
                rebuildMenu()
            } catch {
                Diag.panel.error("rename failed: \(String(describing: error), privacy: .public)")
            }
        }
        panelController.onCreateBoard = { [weak self] name in
            try? self?.store?.createPinboard(name: name)
        }
        panelController.onDeleteBoard = { [weak self] id in
            try? self?.store?.deletePinboard(id: id)
        }
        panelController.onRenameBoard = { [weak self] id, name in
            try? self?.store?.renamePinboard(id: id, to: name)
        }
        panelController.onToggleMembership = { [weak self] item, board in
            guard let store = self?.store else { return }
            let already = ((try? store.membership())?[board] ?? []).contains(item)
            try? store.setMembership(item: item, board: board, on: !already)
            Diag.panel.info("board membership now \(!already, privacy: .public)")
        }
        panelController.onCommit = { item, target in
            let ok = Paster.paste(item, into: target)
            if ok { Sounds.pasted() }
            Diag.paste.info("pasted \(item.kind.rawValue, privacy: .public), \(item.imageData?.count ?? item.text.count, privacy: .public) bytes or chars, into \(target?.bundleIdentifier ?? "nil", privacy: .public), success \(ok, privacy: .public)")
        }
        if !registerPanelHotKey(settings.panelShortcut) {
            // Measured: two apps CAN both register the same hotkey and both
            // fire, so this is not the only way coexistence goes wrong.
            Diag.panel.error("the panel shortcut is already taken by another app")
        }
        startAccessibilityMonitor()
    }

    /// Keeps the whole app honest about the permission, and runs first-run
    /// onboarding when it is missing.
    ///
    /// The monitor runs whether or not the window is shown. Someone who grants
    /// the permission months later, from System Settings and with no Clipd
    /// window open, should see the menu bar icon stop warning at that moment,
    /// not on their next launch.
    private func startAccessibilityMonitor() {
        panelController.trustProbe = { [weak self] in self?.accessibility.isTrusted ?? false }
        accessibility.onChange = { [weak self] trusted in
            guard let self else { return }
            rebuildMenu()                            // repaints the status icon
            panelController.updateTrustBanner()
            onboarding?.permissionChanged(trusted: trusted)
        }
        accessibility.start()

        guard !accessibility.isTrusted, settings.showAccessibilityOnboarding else { return }
        openOnboarding()
    }

    /// Opens the onboarding window, reusing the existing one if it is still
    /// around. Two copies of it would each hold their own "waiting" state and
    /// only one would ever be updated.
    @objc private func openOnboarding() {
        accessibility.check()
        if onboarding == nil {
            onboarding = OnboardingWindowController(monitor: accessibility, settings: settings)
        }
        onboarding?.show()
        Diag.panel.info("onboarding shown, trusted \(self.accessibility.isTrusted, privacy: .public)")
    }

    /// Builds the pasteboard watcher and its two callbacks.
    ///
    /// A separate factory only because a lazy property cannot hold forty lines
    /// of closure and stay readable. It is called exactly once, by the first
    /// read of `watcher`.
    private func makeWatcher() -> PasteboardWatcher {
        PasteboardWatcher(
            onCapture: { [weak self] item in
                guard let self else { return }
                self.history.add(item)
                Sounds.captured()
                // Types and counts only, never the value.
                //
                // %{public} is required. Unified logging redacts every string
                // argument as <private> by default, which makes the diagnostic
                // unreadable and indistinguishable from "nothing happened".
                // Safe here because no clipboard value is ever passed in.
                // Size in the item's own units. "captured 0 chars" for an
                // image reads as a failure when it is a success.
                let size = item.kind == .image
                    ? "\(item.imageData?.count ?? 0) bytes"
                    : "\(item.text.count) chars"
                Diag.capture.info("""
                    captured \(item.kind.rawValue, privacy: .public) \
                    \(size, privacy: .public) from \
                    \(item.sourceBundleID ?? "unknown", privacy: .public), \
                    \(self.history.items.count, privacy: .public) in history
                    """)
                self.rebuildMenu()
                self.scheduleAutoSync()
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
                if case .emptyChange = reason, self.settings.autoClearEnabled,
                   let newest = self.history.items.first,
                   Date().timeIntervalSince(newest.createdAt) < 90 {
                    self.history.removeMostRecent()
                    Diag.capture.info("retracted the most recent item after a clipboard clear (auto-clear rule)")
                    self.rebuildMenu()
                }
            })
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // The menu bar carries the failure too, not just the panel. Without
        // Accessibility macOS discards every synthesised event and reports
        // nothing, so the app would otherwise look completely healthy while
        // pasting nothing at all.
        // From the monitor, not from AXIsProcessTrusted() again. One reader
        // means the icon, the panel banner and the onboarding window always
        // agree, and the answer cannot change halfway through building a menu.
        let trusted = accessibility.isTrusted
        setStatusIcon(trusted: trusted, paused: pause.isPaused(now: Date()))
        let header = NSMenuItem(
            // No app name. The menu hangs off the Clipd icon and the last item
            // says Quit Clipd, so a third mention only made the menu wider:
            // measured, the app name alone was 23 of 230 points, and below
            // about eighteen characters the header stops setting the width at
            // all. The version stays because "which version are you on" is the
            // first question anyone asks.
            title: trusted
                ? "v\(ClipdCore.version) \u{00B7} \(history.items.count) items"
                : "PASTE DISABLED, Accessibility not granted",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        // A statement of the problem is not a way out of it. Somebody who
        // dismissed first run, or who turned the permission off again later,
        // otherwise has to work out for themselves which pane of System
        // Settings this lives in.
        if !trusted {
            let fix = NSMenuItem(title: "Fix This, Grant Accessibility...",
                                 action: #selector(openOnboarding), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        menu.addItem(.separator())

        // Opening the panel from the menu, as well as from the shortcut.
        //
        // The shortcut is discoverable only if you already know it, and it is
        // now changeable, so the menu is the one place that always says what it
        // currently is. The key equivalent is deliberately NOT set on this item:
        // the Carbon hotkey already owns that combination globally, and an
        // NSMenuItem claiming it too would be a second owner of one keystroke.
        let open = NSMenuItem(title: "Open Clipd  \(settings.panelShortcut.display)",
                              action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        // Deliberately no clipboard preview here.
        //
        // It put the last five things you copied on screen every time you
        // opened this menu, including during screen sharing, for no benefit:
        // the entries were not clickable and the panel is one keystroke away.
        // The count above is enough to show the app is working.

        // Pause. This is a privacy control, not a convenience: you pause it
        // before handling something you do not want recorded at all.
        if let label = pause.remainingLabel(now: Date()) {
            let status = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            let resume = NSMenuItem(title: "Resume Clipd",
                                    action: #selector(resumeCapture), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
        } else {
            let pauseItem = NSMenuItem(title: "Pause Clipd", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for duration in PauseDuration.allCases {
                let entry = NSMenuItem(title: duration.label,
                                       action: #selector(pauseCapture(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = duration.rawValue
                submenu.addItem(entry)
            }
            pauseItem.submenu = submenu
            menu.addItem(pauseItem)
        }

        // No key equivalent on Settings, and that is not only about the icon.
        //
        // Cmd+comma in a status menu fires only while the menu is open, because
        // this app is an accessory with no main menu, so it was never a real
        // shortcut. macOS 26 also draws a gear beside any item it recognises as
        // the standard Settings command, and one item with an icon indents
        // every other item in the menu to line up with it.
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(presentSettings),
                                      keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clipd", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc private func pauseCapture(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let duration = PauseDuration(rawValue: raw) else { return }
        pause = PauseState.paused(duration, from: Date())
        lastPausedFlag = true
        Diag.capture.info("paused: \(duration.rawValue, privacy: .public)")
        rebuildMenu()
    }

    @objc private func resumeCapture() {
        pause = .running
        lastPausedFlag = false
        Diag.capture.info("resumed")
        rebuildMenu()
    }

    /// A clipboard glyph, not the word "Clipd". A text title eats menu bar
    /// space that belongs to the user.
    ///
    /// The untrusted state keeps the loud failure: a different symbol, drawn
    /// in orange and NOT as a template, so it stays orange in both light and
    /// dark menu bars. Without Accessibility macOS discards every synthesised
    /// event and reports nothing, so the app must contradict itself visibly.
    private func setStatusIcon(trusted: Bool, paused: Bool) {
        // Returning here means there is no menu bar button to draw into, which
        // only happens when macOS refused us a slot. That is reported once at
        // launch, so this stays quiet: it would otherwise repeat on every
        // capture. Capture, the panel and the hotkey are unaffected.
        guard let button = statusItem?.button else { return }
        button.title = ""
        // A paused app must not look identical to a working one, or you find
        // out it recorded nothing an hour later.
        let description: String
        let image: NSImage?
        if !trusted {
            description = "Clipd, paste disabled"
            image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                            accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        } else if paused {
            description = "Clipd, paused"
            image = NSImage(systemSymbolName: "pause.circle",
                            accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        } else {
            // The real artwork, from art/clipd-menubar-solid.svg.
            //
            // isTemplate is what makes macOS recolour it for a light or dark
            // menu bar. The asset already declares template rendering intent,
            // but setting it here too means a hand copied PNG cannot silently
            // lose it.
            description = "Clipd"
            image = NSImage(named: "MenuBarIcon")
            image?.size = NSSize(width: 18, height: 18)
        }
        image?.isTemplate = trusted
        button.image = image
        button.contentTintColor = trusted ? nil : .systemOrange
        button.toolTip = description
    }

    /// Opens the database and primes the in-memory history from it.
    ///
    /// The panel keeps reading from memory. Rejected: querying SQLite on every
    /// keystroke, which puts disk latency inside the search box for a history
    /// that fits in memory anyway.
    private func openStore() {
        let support = DemoMode.supportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        do {
            let key = try DatabaseKey.loadOrCreate()
            let db = try Database(path: support.appendingPathComponent("clipd.sqlite").path,
                                  key: key)
            try db.migrate()
            let blobs = BlobStore(directory: support.appendingPathComponent("blobs"),
                                  key: BlobStore.symmetricKey(fromHex: key))
            let store = SQLiteStore(database: db, blobs: blobs,
                                    deviceID: Self.deviceIdentifier())

            history.load(try store.loadAll(limit: 500))
            history.onInsert = { item in try? store.insert(item) }
            history.onTouch = { id, date in try? store.touch(id: id, at: date) }
            history.onDelete = { id in try? store.hardDelete(id: id) }

            self.database = db
            self.store = store

            // Link previews. Wired here rather than at panel build time because
            // it needs the store, which does not exist until the database has
            // opened and migrated.
            let previews = LinkPreviewCache(store: store, settings: settings)
            previews.onUpdate = { [weak self] in self?.panelController.refreshCards() }
            self.previews = previews
            panelController.previewProvider = { [weak previews] url in
                previews?.entry(for: url)
            }
            runDedup()
            runRetentionSweep()
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runRetentionSweep() }
            }
            if DemoMode.isOn {
                Diag.capture.info("demo instance, sync disabled")
            } else {
                startAutoSync()
            }
            Diag.capture.info("store opened, \(self.history.items.count, privacy: .public) items restored")
        } catch {
            // Loud, not silent. A failed store means every copy is lost on quit,
            // and the user must not discover that tomorrow.
            Diag.capture.error("STORE FAILED TO OPEN: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stable per Mac, generated once. Identifies the device for sync, not the
    /// user, and never leaves the machine in v1.
    private static func deviceIdentifier() -> String {
        let key = "clipd.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// Expires anything past the retention setting.
    ///
    /// Runs at launch and hourly. Rejected: sweeping on every capture, which
    /// would walk the whole history on every Cmd+C for a job that is not urgent
    /// by even a minute.
    private func runRetentionSweep() {
        guard let store, settings.retention != .forever else { return }
        // Anything filed on a board is exempt. This is what the pinned
        // argument was always for; it was empty until boards existed.
        let pinned = (try? store.pinnedItemIDs()) ?? []
        let doomed = itemsToExpire(history.items, policy: settings.retention,
                                   pinned: pinned, now: Date())
        guard !doomed.isEmpty else { return }
        do {
            try store.expire(ids: doomed, at: Date())
            let survivors = try store.loadAll(limit: 500)
            history.load(survivors)
            Diag.capture.info("retention swept \(doomed.count, privacy: .public) items, \(survivors.count, privacy: .public) remain")
            rebuildMenu()
        } catch {
            Diag.capture.error("retention sweep failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Opens the panel from the menu.
    ///
    /// `show()` rather than `toggle()`: the menu closes as this fires, and a
    /// toggle would then be deciding against a state the user cannot see.
    /// Clicking a menu item called Open Clipd must open Clipd.
    @objc private func openPanel() {
        panelController.show()
    }

    /// Registers the panel shortcut, replacing whatever was registered before.
    ///
    /// Returns false when macOS refuses, which means another app holds it. The
    /// old shortcut is put back in that case, so a failed change never leaves
    /// the app with no way to open its panel at all.
    @discardableResult
    private func registerPanelHotKey(_ shortcut: Shortcut) -> Bool {
        let previous = hotKey
        previous?.unregister()
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) {
            [weak self] in self?.panelController.toggle()
        }
        guard hotKey != nil else {
            hotKey = HotKey(keyCode: settings.panelShortcut.keyCode,
                            modifiers: settings.panelShortcut.carbonModifiers) {
                [weak self] in self?.panelController.toggle()
            }
            return false
        }
        Diag.panel.info("panel shortcut registered")
        return true
    }

    /// Frees the shortcut while the user is recording a new one.
    ///
    /// Without this, pressing the current shortcut inside the recorder opens
    /// the panel over the settings window instead of being recorded, so the one
    /// combination you can never set is the one you already have.
    private func setHotKeyPaused(_ paused: Bool) {
        if paused {
            hotKey?.unregister()
            hotKey = nil
        } else if hotKey == nil {
            registerPanelHotKey(settings.panelShortcut)
        }
    }

    /// Named `presentSettings`, not `openSettings`, and that is load bearing.
    ///
    /// Measured with a throwaway status menu: macOS 26 draws a gear beside any
    /// item whose action selector is called `openSettings`. Not the title, the
    /// selector: the same item titled "Settings..." with any other selector
    /// gets nothing. One item with an icon indents every other item in the menu
    /// to line up with it, which cost 20 points of width and made a five item
    /// menu look like a settings panel.
    @objc private func presentSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings,
                onErase: { [weak self] in self?.eraseAllHistory() },
                onRecordShortcut: { [weak self] shortcut in
                    guard let self, registerPanelHotKey(shortcut) else { return false }
                    settings.panelShortcut = shortcut
                    // The menu prints the shortcut, so it is now out of date.
                    rebuildMenu()
                    Diag.panel.info("panel shortcut changed")
                    return true
                },
                onShortcutRecording: { [weak self] recording in
                    self?.setHotKeyPaused(recording)
                },
                lastSync: { [weak self] in (self?.lastSyncAt, self?.lastSyncSummary) },
                onSyncNow: { [weak self] credentials, passphrase, report in
                    self?.runSync(credentials: credentials, passphrase: passphrase, report: report)
                })
        }
        settingsWindow?.show()
    }

    private func eraseAllHistory() {
        do {
            try store?.eraseAll()
            history.removeAll()
            Diag.capture.info("history erased by the user")
            rebuildMenu()
        } catch {
            Diag.capture.error("erase failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs one sync pass and reports the outcome in the Sync pane.
    ///
    /// Manual only for now. Rejected: syncing on every capture, which would put
    /// a network round trip on the Cmd+C path.
    private func runSync(credentials: R2Credentials, passphrase: String,
                         report: @escaping (String) -> Void) {
        guard let store else { report("The local store is not open."); return }
        // One pass at a time. Two overlapping passes would each write a
        // manifest, and the later one could claim items the earlier one had not
        // finished uploading.
        guard !isSyncing else { report("A sync is already running."); return }
        isSyncing = true
        let deviceID = Self.deviceIdentifier()
        Task {
            do {
                let client = R2Client(credentials: credentials)
                let salt = try await SyncEngine.fetchOrCreateSalt(client: client)
                let key = SyncCrypto.deriveKey(passphrase: passphrase, salt: salt)
                let engine = SyncEngine(client: client, store: store,
                                        deviceID: deviceID, key: key)
                let summary = try await engine.runOnce()
                let refreshed = try store.loadAll(limit: 500)
                Diag.sync.info("sync ok: up \(summary.uploaded, privacy: .public), down \(summary.downloaded, privacy: .public), tombstones \(summary.tombstoned, privacy: .public)")
                await MainActor.run {
                    self.history.load(refreshed)
                    self.isSyncing = false
                    // Duplicates can only arrive via a sync, so this is the
                    // only moment worth checking.
                    self.runDedup()
                    self.lastSyncAt = Date()
                    self.lastSyncSummary = "\(summary.uploaded) up, \(summary.downloaded) down, "
                        + "\(summary.tombstoned) deleted, \(refreshed.count) items"
                    self.rebuildMenu()
                    report("Synced. \(summary.uploaded) uploaded, \(summary.downloaded) downloaded, "
                           + "\(summary.tombstoned) deleted. \(refreshed.count) items here now.")
                }
            } catch {
                // Loud. A silent sync failure means the other Mac quietly
                // diverges and nobody notices for weeks.
                Diag.sync.error("sync failed: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    self.isSyncing = false
                    self.lastSyncSummary = "failed"
                    report("Sync failed: \(error)")
                }
            }
        }
    }

    /// Gives the app an Edit menu so Cmd+C, Cmd+V, Cmd+X and Cmd+A work in
    /// text fields.
    ///
    /// A menu bar only app has no main menu by default, and those shortcuts are
    /// implemented BY the Edit menu, not by the text field. Without this you can
    /// paste into Settings only by right clicking, which is how the bug was
    /// reported. Rejected: overriding performKeyEquivalent on each window, which
    /// would need repeating for every window and would still miss Undo.
    ///
    /// The menu bar is not displayed for an accessory app, so this costs no
    /// screen space. It exists purely to carry the key equivalents.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        // The first item is the application menu. macOS requires it to exist
        // even when nothing is drawn.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Clipd", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // nil target means these travel the responder chain to whatever text
        // field is focused, which is exactly what the standard Edit menu does.
        let entries: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (title, action, key, flags) in entries {
            if title == "Cut" { editMenu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Automatic sync

    /// Three triggers: shortly after launch, every 5 minutes, and a debounced
    /// pass after you stop copying.
    ///
    /// Rejected: syncing on every single copy, which puts a network round trip
    /// on the Cmd+C path. Rejected: syncing only on a timer, which means a
    /// thing you copy and immediately want on the other Mac waits up to five
    /// minutes.
    private func startAutoSync() {
        // A short delay at launch so the first pass does not compete with the
        // rest of startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.autoSync(reason: "launch")
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoSync(reason: "timer") }
        }
    }

    /// Called after every capture. Waits for you to stop copying, so pasting a
    /// run of things produces one sync rather than ten.
    private func scheduleAutoSync() {
        guard settings.autoSyncEnabled else { return }
        syncDebounce?.invalidate()
        syncDebounce = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoSync(reason: "after a copy") }
        }
    }

    private func autoSync(reason: String) {
        guard settings.autoSyncEnabled else { return }
        // Silently does nothing until sync is actually configured.
        guard let (credentials, passphrase) = try? SyncCredentialStore.load() else { return }
        Diag.sync.info("auto sync starting (\(reason, privacy: .public))")
        runSync(credentials: credentials, passphrase: passphrase, report: { _ in })
    }

    /// Folds duplicate content that arrived from the other Mac.
    ///
    /// Each device already refuses a duplicate of something it copied itself.
    /// Sync merges on id, so the same text copied independently on both Macs
    /// produces two rows with identical content and both survive. This collapses
    /// them, keeping the lowest id so BOTH Macs pick the same survivor.
    ///
    /// Runs after every sync rather than on a timer: duplicates can only appear
    /// as a result of a sync, so any other schedule is wasted work.
    private func runDedup() {
        guard let store else { return }
        do {
            // The folding itself lives in DedupRunner so the two device test can
            // drive the exact code the app runs. Testing `planDedup` alone was
            // not enough: the bug that shipped was in how the plan was APPLIED.
            let pinned = (try? store.pinnedItemIDs()) ?? []
            let folded = try applyDedup(in: store, items: history.items, pinned: pinned)
            guard folded > 0 else { return }
            history.load(try store.loadAll(limit: 500))
            Diag.sync.info("deduplicated \(folded, privacy: .public) duplicate items")
            rebuildMenu()
        } catch {
            Diag.sync.error("dedup failed: \(String(describing: error), privacy: .public)")
        }
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
