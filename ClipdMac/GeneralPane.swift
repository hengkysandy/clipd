import AppKit
import ServiceManagement
import ClipdCore

/// General settings: launch at login, how long to keep history, and erase.
final class GeneralPane: NSViewController {
    private let settings: AppSettings
    private let onErase: () -> Void
    private var retentionLabel: NSTextField!

    init(settings: AppSettings, onErase: @escaping () -> Void) {
        self.settings = settings
        self.onErase = onErase
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))

        let launch = NSButton(checkboxWithTitle: "Open at login",
                              target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launch.frame = NSRect(x: 24, y: 246, width: 300, height: 20)
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        root.addSubview(launch)

        let keepTitle = NSTextField(labelWithString: "Keep history for")
        keepTitle.frame = NSRect(x: 24, y: 200, width: 200, height: 18)
        keepTitle.font = .boldSystemFont(ofSize: 13)
        root.addSubview(keepTitle)

        // A slider with named stops, matching the reference app. Rejected: a
        // popup menu, which hides that the choices are ordered.
        let slider = NSSlider(value: Double(index(of: settings.retention)),
                              minValue: 0,
                              maxValue: Double(RetentionPolicy.allCases.count - 1),
                              target: self, action: #selector(retentionChanged(_:)))
        slider.frame = NSRect(x: 24, y: 168, width: 512, height: 24)
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
            label.frame = NSRect(x: centre - label.frame.width / 2, y: 146,
                                 width: label.frame.width, height: 14)
            root.addSubview(label)
        }

        retentionLabel = NSTextField(labelWithString: describe(settings.retention))
        retentionLabel.frame = NSRect(x: 24, y: 110, width: 512, height: 18)
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
        preferredContentSize = NSSize(width: 560, height: 300)
        for sub in root.subviews { sub.autoresizingMask = [.minYMargin] }
        view = root
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
