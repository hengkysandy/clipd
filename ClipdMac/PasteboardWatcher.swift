import AppKit
import ClipdCore

/// Polls NSPasteboard and reports changes. Decides nothing.
///
/// There is no clipboard change notification on macOS, so polling is the only
/// option. Measured at 200ms: 0.0% CPU and a flat 9.1 MB resident size, so the
/// interval is not a design constraint.
@MainActor
final class PasteboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let settings: CaptureSettings

    private let onCapture: (HistoryItem) -> Void
    private let onRefusal: (CaptureRefusal) -> Void

    init(settings: CaptureSettings = .standard,
         onCapture: @escaping (HistoryItem) -> Void,
         onRefusal: @escaping (CaptureRefusal) -> Void) {
        self.settings = settings
        self.onCapture = onCapture
        self.onRefusal = onRefusal
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Read the frontmost app before touching the pasteboard, so the value
        // is as close as possible to the moment of the change.
        let front = NSWorkspace.shared.frontmostApplication
        let items = pasteboard.pasteboardItems ?? []

        var types: [String] = []
        var totalBytes = 0
        for item in items {
            for type in item.types {
                types.append(type.rawValue)
                totalBytes += item.data(forType: type)?.count ?? 0
            }
        }

        let snapshot = PasteboardSnapshot(
            types: types, totalBytes: totalBytes, itemCount: items.count,
            sourceBundleID: front?.bundleIdentifier)

        switch decideCapture(snapshot, settings: settings) {
        case .refuse(let reason):
            // NEVER log the value. Types, sizes and reasons only. During
            // probing a diagnostic printed a text preview and wrote a real
            // password into a log file.
            onRefusal(reason)
        case .store:
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
                // Images are captured in the storage plan. The skeleton proves
                // the text path end to end first.
                onRefusal(.noUsableContent)
                return
            }
            let item = HistoryItem(
                text: text,
                sourceBundleID: front?.bundleIdentifier,
                sourceName: front?.localizedName,
                createdAt: Date())
            onCapture(item)
        }
    }
}
