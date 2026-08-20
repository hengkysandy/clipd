import AppKit
import ClipdCore

/// What a link card can show beyond its address.
struct LinkPreviewEntry {
    let title: String?
    let image: NSImage?

    var isEmpty: Bool { title == nil && image == nil }
}

/// Decides whether a link card has a picture yet, and asks for one if not.
///
/// Three layers, in this order: memory, the database, the network. Only the
/// last one is optional, and only the last one can be slow.
///
/// The panel asks for a card that is about to appear on screen, so a link
/// sitting at position 40 in the history is never fetched until someone
/// actually scrolls to it. That is not an optimisation. It means the app asks
/// about the links you look at, rather than announcing your whole clipboard
/// history to forty different servers the first time it launches.
@MainActor
final class LinkPreviewCache {
    private let store: SQLiteStore
    private let settings: AppSettings
    /// Every URL we already know the answer for, including "nothing to show".
    private var entries: [String: LinkPreviewEntry] = [:]
    private var inFlight: Set<String> = []

    /// Fired when a fetch lands, so the panel can redraw the card.
    var onUpdate: (() -> Void)?

    init(store: SQLiteStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    /// Nil means "nothing to show yet", which the card draws as the compass.
    func entry(for url: String) -> LinkPreviewEntry? {
        guard settings.linkPreviewsEnabled else { return nil }
        if let known = entries[url] { return known.isEmpty ? nil : known }
        if let row = try? store.linkPreview(for: url) {
            let entry = LinkPreviewEntry(title: row.title,
                                         image: row.image.flatMap { NSImage(data: $0) })
            entries[url] = entry
            return entry.isEmpty ? nil : entry
        }
        fetch(url)
        return nil
    }

    /// Drops everything, in memory and on disk.
    ///
    /// Called when the switch is turned off. Leaving the pictures in the
    /// database would mean the setting stops new fetches but keeps the evidence
    /// of the old ones, which is not what "off" means to anyone.
    func forgetEverything() {
        entries = [:]
        try? store.eraseLinkPreviews()
    }

    private func fetch(_ url: String) {
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task { [weak self] in
            let outcome = await LinkPreviewFetcher.fetch(url)
            self?.absorb(outcome, for: url)
        }
    }

    /// Writes the answer down, whatever it was.
    ///
    /// A refusal and a failure are stored exactly like a success. Without that
    /// row the same page would be asked again every time the panel opened, and
    /// a site that refuses us once would be hit forever.
    ///
    /// The status never contains the URL. It goes into a log line, and a log
    /// line naming the links you copy is the thing this app is supposed to
    /// avoid.
    private func absorb(_ outcome: LinkPreviewFetcher.Outcome, for url: String) {
        inFlight.remove(url)
        try? store.saveLinkPreview(url: url, title: outcome.title,
                                   image: outcome.image, status: outcome.status)
        entries[url] = LinkPreviewEntry(title: outcome.title,
                                        image: outcome.image.flatMap { NSImage(data: $0) })
        Diag.panel.info("link preview \(outcome.status, privacy: .public)")
        onUpdate?()
    }
}
