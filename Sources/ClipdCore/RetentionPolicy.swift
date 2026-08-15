import Foundation

public enum RetentionPolicy: String, CaseIterable, Equatable, Sendable {
    case day
    case week
    case month
    case year
    case forever

    public var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .forever: return "Forever"
        }
    }

    /// Nil means never expire.
    ///
    /// Approximate months and years on purpose. A clipboard history is not an
    /// accounting ledger, and calendar arithmetic here would buy nothing except
    /// timezone bugs.
    public var maxAge: TimeInterval? {
        let day: TimeInterval = 24 * 3600
        switch self {
        case .day: return day
        case .week: return 7 * day
        case .month: return 30 * day
        case .year: return 365 * day
        case .forever: return nil
        }
    }
}

/// Which items the retention sweep should remove.
///
/// Pure, and takes the clock as a parameter, so every boundary case is testable
/// with no waiting and no database.
public func itemsToExpire(_ items: [HistoryItem],
                          policy: RetentionPolicy,
                          pinned: Set<UUID>,
                          now: Date) -> [UUID] {
    guard let maxAge = policy.maxAge else { return [] }
    return items.compactMap { item in
        // Pinned wins over everything. Otherwise a one week setting quietly
        // eats the snippets that were deliberately kept.
        guard !pinned.contains(item.id) else { return nil }
        let age = now.timeIntervalSince(item.createdAt)
        // Strictly greater, so an item exactly on the boundary survives.
        // Off by one here silently deletes a day of history, and keeping is
        // the safe direction to be wrong in.
        //
        // A negative age means the item is dated in the future, which happens
        // when the clock jumps. Deleting data because of a clock change would
        // be unforgivable, so those are kept too.
        return age > maxAge ? item.id : nil
    }
}
