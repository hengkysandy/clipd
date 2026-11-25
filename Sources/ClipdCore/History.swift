import Foundation

/// The in-memory history for the walking skeleton.
///
/// Rejected: putting the database in first. The platform risks all live in the
/// shell, and this project already found two false assumptions there, so the
/// end to end path is proved before the storage layer is written.
public final class History {
    private var storage: [HistoryItem] = []
    private let limit: Int

    /// Persistence hooks. Core defines the shape; the shell supplies the
    /// database. Rejected: Core importing SQLCipher, which would make every
    /// Core test need a database file and lose the millisecond test suite.
    public var onInsert: ((HistoryItem) -> Void)?
    public var onTouch: ((UUID, Date) -> Void)?
    public var onDelete: ((UUID) -> Void)?

    public init(limit: Int = 500) {
        self.limit = limit
    }

    /// Replaces the in-memory contents, newest first. Used once at launch.
    /// Does NOT fire the persistence hooks: these rows came from the database,
    /// and echoing them back would rewrite the whole history on every launch.
    public func load(_ items: [HistoryItem]) {
        storage = items
    }

    /// Clears the in-memory cache. Used by Erase History, after the store has
    /// already been emptied. Does not fire onDelete for each item: the caller
    /// erased the database in one operation, not row by row.
    public func removeAll() {
        storage.removeAll()
    }

    /// Newest first.
    public var items: [HistoryItem] { storage }

    /// Returns true if a new item was inserted, false if an existing identical
    /// item was moved to the top instead.
    @discardableResult
    public func add(_ item: HistoryItem) -> Bool {
        if let existing = storage.firstIndex(where: { $0.contentHash == item.contentHash }) {
            let moved = storage.remove(at: existing)
            storage.insert(moved, at: 0)
            onTouch?(moved.id, item.createdAt)
            return false
        }
        storage.insert(item, at: 0)
        if storage.count > limit { storage.removeLast(storage.count - limit) }
        onInsert?(item)
        return true
    }

    /// Used by the auto-clear rule: a cleared clipboard retracts the item that
    /// was just captured. Must be safe on an empty history.
    public func removeMostRecent() {
        guard !storage.isEmpty else { return }
        let removed = storage.removeFirst()
        onDelete?(removed.id)
    }

    /// Drops one item from memory only, without calling `onDelete`.
    ///
    /// For when the store has already been told. The Delete key now deletes in
    /// the store first, because the item may be one of the many the in-memory
    /// history never held: `remove(id:)` only reaches the store when the item
    /// is among the newest 500, so deleting anything older from search or a
    /// board tab did nothing at all and the card simply stayed.
    @discardableResult
    public func discard(id: UUID) -> Bool {
        guard let index = storage.firstIndex(where: { $0.id == id }) else { return false }
        storage.remove(at: index)
        return true
    }

    /// Deletes one item by identity. Returns true if something was removed.
    ///
    /// Identity rather than index, because the panel filters: the card at
    /// position 3 on screen is not row 3 of the history. Deleting by index
    /// would remove the wrong item whenever a search is active.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let index = storage.firstIndex(where: { $0.id == id }) else { return false }
        storage.remove(at: index)
        onDelete?(id)
        return true
    }

    /// Plain token matching, every token must be present, any order, case
    /// insensitive. Rejected: relevance ranking, which buries the thing you
    /// copied 30 seconds ago under an older better match. A clipboard history
    /// is a timeline.
    public func search(_ query: String) -> [HistoryItem] {
        filterByQuery(storage, query)
    }
}

/// The one matching rule for typed text, for any list of items.
///
/// A free function so the panel can apply EXACTLY the same rule to a pinboard's
/// items, which are loaded from the store rather than from the in-memory
/// history. Two copies of this rule would drift, and the symptom would be a
/// word that finds a card on Clipboard but not on the board it is filed on.
///
/// An empty query returns the list untouched, which is what "no filter" means.
public func filterByQuery(_ items: [HistoryItem], _ query: String) -> [HistoryItem] {
    let tokens = query.lowercased()
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)
    guard !tokens.isEmpty else { return items }
    return items.filter { item in
        // Preview as well as text, so images are reachable. An image has no
        // text at all, and its preview is "Image 2560 x 1664", which makes
        // typing "image" or a dimension find it.
        //
        // The title too, which is the whole point of naming an item: a name
        // makes it findable by a word that appears nowhere in the content.
        let haystack = (item.text + " " + item.preview + " " + (item.title ?? "")).lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
