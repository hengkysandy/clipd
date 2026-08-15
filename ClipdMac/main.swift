import AppKit
import ClipdCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var watcher: PasteboardWatcher!
    private var hotKey: HotKey?
    private var panelController: PanelController!
    let history = History()
    private var pause = PauseState.running
    private var pauseTicker: Timer?
    private var settings = AppSettings()
    private var settingsWindow: SettingsWindowController?
    private var retentionTimer: Timer?
    private var syncTimer: Timer?
    private var syncDebounce: Timer?
    private var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncSummary: String?
    private var database: Database?
    private var store: SQLiteStore?
    private var lastPausedFlag = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        openStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()   // sets the icon too

        watcher = PasteboardWatcher(
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

        panelController = PanelController(history: history)
        panelController.boardProvider = { [weak self] in
            guard let store = self?.store else { return ([], [:]) }
            return ((try? store.allPinboards()) ?? [], (try? store.membership()) ?? [:])
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
        hotKey = HotKey { [weak self] in
            self?.panelController.toggle()
        }
        if hotKey == nil {
            // Measured: two apps CAN both register the same hotkey and both
            // fire, so this is not the only way coexistence goes wrong.
            Diag.panel.error("Cmd+Shift+V is already taken. If the real Paste app is running, quit it.")
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // The menu bar carries the failure too, not just the panel. Without
        // Accessibility macOS discards every synthesised event and reports
        // nothing, so the app would otherwise look completely healthy while
        // pasting nothing at all.
        let trusted = AXIsProcessTrusted()
        setStatusIcon(trusted: trusted, paused: pause.isPaused(now: Date()))
        let header = NSMenuItem(
            title: trusted
                ? "Clipd \(ClipdCore.version), \(history.items.count) items"
                : "PASTE DISABLED, Accessibility not granted",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
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

        menu.addItem(soundMenu(title: "Copy sound", slot: .capture))
        menu.addItem(soundMenu(title: "Paste sound", slot: .paste))

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clipd", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
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

    /// A submenu listing every system sound plus Off, with the current choice
    /// ticked. Choosing one plays it immediately, because picking a sound from
    /// a list of names you cannot hear is guesswork.
    private func soundMenu(title: String, slot: Sounds.Slot) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = Sounds.name(for: slot)

        let off = NSMenuItem(title: "Off", action: #selector(chooseSound(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = [slot.rawValue, ""]
        off.state = current == nil ? .on : .off
        submenu.addItem(off)
        submenu.addItem(.separator())

        for name in Sounds.available {
            let entry = NSMenuItem(title: name, action: #selector(chooseSound(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [slot.rawValue, name]
            entry.state = current == name ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func chooseSound(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let slot = Sounds.Slot(rawValue: pair[0]) else { return }
        let name = pair[1].isEmpty ? nil : pair[1]
        Sounds.setName(name, for: slot)
        if let name { Sounds.play(named: name) }
        Diag.capture.info("sound for \(slot.rawValue, privacy: .public) set to \(name ?? "off", privacy: .public)")
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
        guard let button = statusItem.button else { return }
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
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("Clipd")
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
            runRetentionSweep()
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runRetentionSweep() }
            }
            startAutoSync()
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

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings,
                onErase: { [weak self] in self?.eraseAllHistory() },
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

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only. Rejected: .regular, which puts an icon in the Dock and
// gives the app a main menu it has no use for.
app.setActivationPolicy(.accessory)
app.run()
