import AppKit
import ServiceManagement
import ClipdCore

/// General settings: launch at login, the panel shortcut, sounds, how long to
/// keep history, and erase.
final class GeneralPane: NSViewController {
    private let settings: AppSettings
    private let onErase: () -> Void
    private let onRecordShortcut: (Shortcut) -> Bool
    private let onShortcutRecording: (Bool) -> Void
    private var retentionLabel: NSTextField!
    private var shortcutField: ShortcutField!

    init(settings: AppSettings, onErase: @escaping () -> Void,
         onRecordShortcut: @escaping (Shortcut) -> Bool,
         onShortcutRecording: @escaping (Bool) -> Void) {
        self.settings = settings
        self.onErase = onErase
        self.onRecordShortcut = onRecordShortcut
        self.onShortcutRecording = onShortcutRecording
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))

        // A heading for one checkbox, because every other group in this pane has
        // one and this group did not. Without it the checkbox read as a stray
        // line above the first real section, and it was missed.
        let startupTitle = NSTextField(labelWithString: "Startup")
        startupTitle.frame = NSRect(x: 24, y: 408, width: 160, height: 18)
        startupTitle.font = .boldSystemFont(ofSize: 13)
        root.addSubview(startupTitle)

        let launch = NSButton(checkboxWithTitle: "Open at login",
                              target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launch.frame = NSRect(x: 24, y: 380, width: 300, height: 20)
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        root.addSubview(launch)

        // MARK: The shortcut

        let shortcutTitle = NSTextField(labelWithString: "Open the panel with")
        shortcutTitle.frame = NSRect(x: 24, y: 336, width: 160, height: 18)
        shortcutTitle.font = .boldSystemFont(ofSize: 13)
        root.addSubview(shortcutTitle)

        shortcutField = ShortcutField(frame: NSRect(x: 196, y: 330, width: 120, height: 26),
                                      shortcut: settings.panelShortcut)
        shortcutField.onRecord = { [weak self] in self?.onRecordShortcut($0) ?? false }
        shortcutField.onRecordingChanged = { [weak self] in self?.onShortcutRecording($0) }
        root.addSubview(shortcutField)

        let reset = NSButton(title: "Use Default", target: self,
                             action: #selector(resetShortcut))
        reset.frame = NSRect(x: 328, y: 328, width: 120, height: 28)
        reset.bezelStyle = .rounded
        root.addSubview(reset)

        let shortcutHint = NSTextField(wrappingLabelWithString:
            "Click the box, then press the keys. It needs ⌘, ⌥ or ⌃ in it, or it "
            + "would swallow that key in every app. If another app already holds "
            + "the combination, the box says so and nothing changes.")
        shortcutHint.frame = NSRect(x: 24, y: 288, width: 512, height: 34)
        shortcutHint.font = .systemFont(ofSize: 11)
        shortcutHint.textColor = .secondaryLabelColor
        root.addSubview(shortcutHint)

        // MARK: Sounds
        //
        // These were two submenus in the menu bar. They are settings, and the
        // menu bar is for things you do, not things you configure. Copy and
        // paste stay separate: a tick on every Cmd+C is intrusive, a sound on
        // paste is rare enough to be useful.

        let soundTitle = NSTextField(labelWithString: "Sounds")
        soundTitle.frame = NSRect(x: 24, y: 252, width: 160, height: 18)
        soundTitle.font = .boldSystemFont(ofSize: 13)
        root.addSubview(soundTitle)

        addSoundRow(to: root, label: "On copy", slot: .capture, x: 24, y: 220)
        addSoundRow(to: root, label: "On paste", slot: .paste, x: 290, y: 220)

        // MARK: How long to keep things

        let keepTitle = NSTextField(labelWithString: "Keep history for")
        keepTitle.frame = NSRect(x: 24, y: 172, width: 200, height: 18)
        keepTitle.font = .boldSystemFont(ofSize: 13)
        root.addSubview(keepTitle)

        // A slider with named stops, matching the reference app. Rejected: a
        // popup menu, which hides that the choices are ordered.
        let slider = NSSlider(value: Double(index(of: settings.retention)),
                              minValue: 0,
                              maxValue: Double(RetentionPolicy.allCases.count - 1),
                              target: self, action: #selector(retentionChanged(_:)))
        slider.frame = NSRect(x: 24, y: 140, width: 512, height: 24)
        slider.numberOfTickMarks = RetentionPolicy.allCases.count
        slider.allowsTickMarkValuesOnly = true
        root.addSubview(slider)

        // One label per tick, centred on its own tick.
        //
        // Rejected: a single string with padding between the words, which is
        // what this was. The words have different widths, so "Day" and
        // "Forever" drifted away from the ticks they name.
        let count = RetentionPolicy.allCases.count
        let usable = slider.frame.width - 20   // the knob inset at each end
        for (offset, policy) in RetentionPolicy.allCases.enumerated() {
            let centre = slider.frame.minX + 10
                + usable * CGFloat(offset) / CGFloat(count - 1)
            let label = NSTextField(labelWithString: policy.label)
            label.font = .systemFont(ofSize: 9)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.sizeToFit()
            label.frame = NSRect(x: centre - label.frame.width / 2, y: 118,
                                 width: label.frame.width, height: 14)
            root.addSubview(label)
        }

        retentionLabel = NSTextField(labelWithString: describe(settings.retention))
        retentionLabel.frame = NSRect(x: 24, y: 84, width: 512, height: 18)
        retentionLabel.font = .systemFont(ofSize: 11)
        retentionLabel.textColor = .secondaryLabelColor
        root.addSubview(retentionLabel)

        let erase = NSButton(title: "Erase History...", target: self,
                             action: #selector(eraseHistory))
        erase.frame = NSRect(x: 400, y: 20, width: 136, height: 28)
        erase.bezelStyle = .rounded
        root.addSubview(erase)

        // Without this the tab controller stretches the pane to fill an
        // oversized window and the content sinks to the bottom, because these
        // subviews are laid out from the bottom edge.
        preferredContentSize = NSSize(width: 560, height: 440)
        for sub in root.subviews { sub.autoresizingMask = [.minYMargin] }
        view = root
    }

    /// One "On copy" or "On paste" row: a label and a popup of the system
    /// sounds, with Off first.
    ///
    /// Choosing one plays it straight away, exactly as the old menu did.
    /// Picking a sound from a list of names you cannot hear is guesswork.
    private func addSoundRow(to root: NSView, label: String, slot: Sounds.Slot,
                             x: CGFloat, y: CGFloat) {
        let title = NSTextField(labelWithString: label)
        title.frame = NSRect(x: x, y: y + 4, width: 64, height: 18)
        title.font = .systemFont(ofSize: 12)
        root.addSubview(title)

        let popup = NSPopUpButton(frame: NSRect(x: x + 70, y: y, width: 160, height: 26))
        popup.addItem(withTitle: "Off")
        popup.menu?.addItem(.separator())
        popup.addItems(withTitles: Sounds.available)
        popup.selectItem(withTitle: Sounds.name(for: slot) ?? "Off")
        popup.target = self
        popup.action = #selector(soundChanged(_:))
        // The slot travels with the control, so one action serves both rows.
        popup.identifier = NSUserInterfaceItemIdentifier(slot.rawValue)
        root.addSubview(popup)
    }

    @objc private func soundChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let slot = Sounds.Slot(rawValue: raw) else { return }
        let chosen = sender.titleOfSelectedItem
        let name = (chosen == "Off" || chosen == nil) ? nil : chosen
        Sounds.setName(name, for: slot)
        if let name { Sounds.play(named: name) }
        Diag.capture.info("sound for \(slot.rawValue, privacy: .public) set to \(name ?? "off", privacy: .public)")
    }

    @objc private func resetShortcut() {
        guard onRecordShortcut(.panelDefault) else { return }
        shortcutField.show(.panelDefault)
    }

    private func index(of policy: RetentionPolicy) -> Int {
        RetentionPolicy.allCases.firstIndex(of: policy) ?? RetentionPolicy.allCases.count - 1
    }

    private func describe(_ policy: RetentionPolicy) -> String {
        switch policy {
        case .forever:
            return "Nothing is deleted automatically."
        case .threeMonths, .sixMonths:
            // "older than one 3 months" reads badly, so drop the article.
            return "Items older than \(policy.label.lowercased()) are removed automatically. Pinned items are kept."
        default:
            return "Items older than one \(policy.label.lowercased()) are removed automatically. Pinned items are kept."
        }
    }

    @objc private func retentionChanged(_ sender: NSSlider) {
        let policy = RetentionPolicy.allCases[Int(sender.doubleValue.rounded())]
        settings.retention = policy
        retentionLabel.stringValue = describe(policy)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Loud, not silent. Otherwise the checkbox looks set and the app
            // does not actually launch, which the user finds out weeks later.
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    @objc private func eraseHistory() {
        let alert = NSAlert()
        alert.messageText = "Erase all clipboard history?"
        alert.informativeText = "Every item and every stored image is deleted. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        // Destructive and irreversible, so it asks first and Cancel is the
        // safe default position.
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onErase()
    }
}
