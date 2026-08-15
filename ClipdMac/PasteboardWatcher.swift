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

    /// Set by the app while capture is suspended.
    var isPaused: () -> Bool = { false }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        // Consume the change even while paused. Without this, resuming would
        // immediately capture whatever was copied during the pause, which
        // defeats the entire point of pausing before handling something private.
        lastChangeCount = current
        guard !isPaused() else { return }

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
            // Images first. A screenshot copy carries public.png and no usable
            // string, and a Finder copy carries a file URL whose string is a
            // path. Checking text first would turn both into text cards.
            if let item = imageItem(from: items, front: front) {
                onCapture(item)
                return
            }
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
                onRefusal(.noUsableContent)
                return
            }
            onCapture(HistoryItem(
                text: text,
                sourceBundleID: front?.bundleIdentifier,
                sourceName: front?.localizedName,
                createdAt: Date()))
        }
    }

    /// Builds an image item if the pasteboard carries picture bytes.
    ///
    /// Prefers PNG, which is what macOS actually hands over for a screenshot
    /// and is already compressed. TIFF is the fallback and is much larger, so
    /// it gets re-encoded to PNG rather than stored raw.
    private func imageItem(from items: [NSPasteboardItem],
                           front: NSRunningApplication?) -> HistoryItem? {
        let pngType = NSPasteboard.PasteboardType("public.png")
        for item in items {
            var data: Data?
            if item.types.contains(pngType) {
                data = item.data(forType: pngType)
            } else if item.types.contains(.tiff), let tiff = item.data(forType: .tiff) {
                data = NSBitmapImageRep(data: tiff)?
                    .representation(using: .png, properties: [:])
            }
            guard let data, let image = NSImage(data: data) else { continue }
            let rep = image.representations.first
            let width = rep?.pixelsWide ?? Int(image.size.width)
            let height = rep?.pixelsHigh ?? Int(image.size.height)
            guard width > 0, height > 0 else { continue }
            return HistoryItem(
                imageData: data, pixelWidth: width, pixelHeight: height,
                sourceBundleID: front?.bundleIdentifier,
                sourceName: front?.localizedName,
                createdAt: Date())
        }
        return nil
    }
}
