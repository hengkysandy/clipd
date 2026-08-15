import Foundation

/// The in-memory history for the walking skeleton.
///
/// Rejected: putting the database in first. The platform risks all live in the
/// shell, and this project already found two false assumptions there, so the
/// end to end path is proved before the storage layer is written.
public final class History {
    private var storage: [HistoryItem] = []
    private let limit: Int

    public init(limit: Int = 500) {
        self.limit = limit
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
            return false
        }
        storage.insert(item, at: 0)
        if storage.count > limit { storage.removeLast(storage.count - limit) }
        return true
    }

    /// Used by the auto-clear rule: a cleared clipboard retracts the item that
    /// was just captured. Must be safe on an empty history.
    public func removeMostRecent() {
        guard !storage.isEmpty else { return }
        storage.removeFirst()
    }

    /// Plain token matching, every token must be present, any order, case
    /// insensitive. Rejected: relevance ranking, which buries the thing you
    /// copied 30 seconds ago under an older better match. A clipboard history
    /// is a timeline.
    public func search(_ query: String) -> [HistoryItem] {
        let tokens = query.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return storage }
        return storage.filter { item in
            let haystack = item.text.lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}
