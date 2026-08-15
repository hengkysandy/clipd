import AppKit
import ClipdCore

/// Sync settings: R2 credentials, the shared passphrase, and a manual sync.
final class SyncPane: NSViewController {
    private let onSyncNow: (R2Credentials, String, @escaping (String) -> Void) -> Void
    private let settings: AppSettings
    private let lastSync: () -> (Date?, String?)
    private var autoBox: NSButton!

    private var accountField: NSTextField!
    private var keyField: NSTextField!
    private var secretField: NSSecureTextField!
    private var bucketField: NSTextField!
    private var passphraseField: NSSecureTextField!
    private var statusLabel: NSTextField!

    init(settings: AppSettings,
         lastSync: @escaping () -> (Date?, String?),
         onSyncNow: @escaping (R2Credentials, String, @escaping (String) -> Void) -> Void) {
        self.settings = settings
        self.lastSync = lastSync
        self.onSyncNow = onSyncNow
        super.init(nibName: nil, bundle: nil)
        title = "Sync"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))

        let intro = NSTextField(wrappingLabelWithString:
            "Your history is encrypted on this Mac before it is uploaded, so Cloudflare "
            + "stores data it cannot read. Use the same passphrase on both Macs.")
        intro.frame = NSRect(x: 24, y: 352, width: 472, height: 34)
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        root.addSubview(intro)

        var y = 312

        func label(_ text: String) {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 24, y: y, width: 160, height: 18)
            l.alignment = .right
            root.addSubview(l)
        }
        func place<T: NSTextField>(_ f: T, _ placeholder: String) -> T {
            f.frame = NSRect(x: 192, y: y - 4, width: 304, height: 24)
            f.placeholderString = placeholder
            root.addSubview(f)
            y -= 34
            return f
        }

        label("Account ID"); accountField = place(NSTextField(), "32 hex characters")
        label("Access Key ID"); keyField = place(NSTextField(), "32 hex characters")
        label("Secret Access Key"); secretField = place(NSSecureTextField(), "64 hex characters")
        label("Bucket"); bucketField = place(NSTextField(), "bucket name")
        label("Sync passphrase"); passphraseField = place(NSSecureTextField(), "the same on both Macs")

        let warning = NSTextField(wrappingLabelWithString:
            "If you lose this passphrase nothing can be recovered. It is never sent to Cloudflare.")
        warning.frame = NSRect(x: 192, y: y - 8, width: 304, height: 30)
        warning.font = .systemFont(ofSize: 10)
        warning.textColor = .secondaryLabelColor
        root.addSubview(warning)

        autoBox = NSButton(checkboxWithTitle:
            "Sync automatically: at launch, every 5 minutes, and after you stop copying",
            target: self, action: #selector(toggleAuto(_:)))
        autoBox.frame = NSRect(x: 24, y: 104, width: 472, height: 20)
        autoBox.state = settings.autoSyncEnabled ? .on : .off
        root.addSubview(autoBox)

        statusLabel = NSTextField(wrappingLabelWithString: "Not configured.")
        statusLabel.frame = NSRect(x: 24, y: 62, width: 472, height: 34)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        root.addSubview(statusLabel)

        let save = NSButton(title: "Save", target: self, action: #selector(saveCredentials))
        save.frame = NSRect(x: 192, y: 20, width: 90, height: 28)
        save.bezelStyle = .rounded
        root.addSubview(save)

        let syncNow = NSButton(title: "Sync Now", target: self, action: #selector(syncNow))
        syncNow.frame = NSRect(x: 288, y: 20, width: 100, height: 28)
        syncNow.bezelStyle = .rounded
        syncNow.keyEquivalent = "\r"
        root.addSubview(syncNow)

        let forget = NSButton(title: "Forget", target: self, action: #selector(forget))
        forget.frame = NSRect(x: 394, y: 20, width: 90, height: 28)
        forget.bezelStyle = .rounded
        root.addSubview(forget)

        loadExisting()
        preferredContentSize = NSSize(width: 520, height: 400)
        for sub in root.subviews { sub.autoresizingMask = [.minYMargin] }
        view = root
    }

    /// Reloads the form from the Keychain every time the pane appears.
    ///
    /// The settings window controller is retained and reused, so without this
    /// an edit you made and did not save is still sitting in the field the next
    /// time you open it. That is worse than merely untidy: you could reopen,
    /// see a value you never saved, and press Save over your real credentials.
    override func viewWillAppear() {
        super.viewWillAppear()
        loadExisting()
        autoBox.state = settings.autoSyncEnabled ? .on : .off
    }

    @objc private func toggleAuto(_ sender: NSButton) {
        settings.autoSyncEnabled = sender.state == .on
    }

    /// Shows when the last pass ran, so automatic sync is visible rather than
    /// something you have to trust silently.
    private func lastSyncText() -> String {
        let (at, summary) = lastSync()
        guard let at, let summary else { return "" }
        let ago = Int(Date().timeIntervalSince(at))
        let when = ago < 60 ? "\(ago)s ago" : "\(ago / 60) min ago"
        return "  Last sync \(when): \(summary)."
    }

    private func loadExisting() {
        secretField.stringValue = ""
        passphraseField.stringValue = ""
        guard let (credentials, _) = try? SyncCredentialStore.load() else {
            accountField.stringValue = ""
            keyField.stringValue = ""
            bucketField.stringValue = ""
            statusLabel.stringValue = "Not configured."
            return
        }
        accountField.stringValue = credentials.accountID
        keyField.stringValue = credentials.accessKeyID
        bucketField.stringValue = credentials.bucket
        // The secret and passphrase are deliberately NOT filled back in. Showing
        // them again would put them on screen during screen sharing for no gain.
        secretField.placeholderString = "saved, leave blank to keep"
        passphraseField.placeholderString = "saved, leave blank to keep"
        statusLabel.stringValue = "Configured. Credentials are in your Keychain." + lastSyncText()
    }

    private func currentCredentials() -> (R2Credentials, String)? {
        let existing = try? SyncCredentialStore.load()
        let secret = secretField.stringValue.isEmpty
            ? (existing?.0.secretAccessKey ?? "") : secretField.stringValue
        let passphrase = passphraseField.stringValue.isEmpty
            ? (existing?.1 ?? "") : passphraseField.stringValue
        guard !accountField.stringValue.isEmpty, !keyField.stringValue.isEmpty,
              !secret.isEmpty, !bucketField.stringValue.isEmpty, !passphrase.isEmpty else {
            statusLabel.stringValue = "Fill in every field first."
            return nil
        }
        return (R2Credentials(accountID: accountField.stringValue.trimmingCharacters(in: .whitespaces),
                              accessKeyID: keyField.stringValue.trimmingCharacters(in: .whitespaces),
                              secretAccessKey: secret.trimmingCharacters(in: .whitespaces),
                              bucket: bucketField.stringValue.trimmingCharacters(in: .whitespaces)),
                passphrase)
    }

    @objc private func saveCredentials() {
        guard let (credentials, passphrase) = currentCredentials() else { return }
        do {
            try SyncCredentialStore.save(credentials, passphrase: passphrase)
            secretField.stringValue = ""
            passphraseField.stringValue = ""
            loadExisting()
            statusLabel.stringValue = "Saved to your Keychain."
        } catch {
            statusLabel.stringValue = "Could not save: \(error)"
        }
    }

    @objc private func syncNow() {
        guard let (credentials, passphrase) = currentCredentials() else { return }
        statusLabel.stringValue = "Syncing..."
        onSyncNow(credentials, passphrase) { [weak self] message in
            self?.statusLabel.stringValue = message
        }
    }

    @objc private func forget() {
        try? SyncCredentialStore.clear()
        accountField.stringValue = ""
        keyField.stringValue = ""
        secretField.stringValue = ""
        bucketField.stringValue = ""
        passphraseField.stringValue = ""
        statusLabel.stringValue = "Credentials removed from your Keychain."
    }
}
