import Foundation

/// One duplicate group: the row to keep, and the rows to fold into it.
public struct DedupPlan: Equatable, Sendable {
    public let survivor: UUID
    public let doomed: [UUID]
    /// The newest `createdAt` across the whole group.
    ///
    /// The survivor inherits it, so folding two copies does not drag the item
    /// back down the history to the age of the older one.
    public let newestCreatedAt: Date

    public init(survivor: UUID, doomed: [UUID], newestCreatedAt: Date) {
        self.survivor = survivor
        self.doomed = doomed
        self.newestCreatedAt = newestCreatedAt
    }
}

/// Finds items that are the same content arriving from two devices.
///
/// Each Mac already refuses a duplicate of something it copied itself, on
/// content hash. Sync merges on id, so the same text copied independently on
/// both Macs produces two rows with different ids and identical content, and
/// both survive. This collapses them.
///
/// **The survivor is the OLDEST id, chosen by UUID string order.** Both Macs
/// must independently pick the same survivor or they will fold each other's
/// rows in opposite directions forever, each undoing the other on every pass.
/// Sorting by `createdAt` cannot do that: two devices disagree about clocks,
/// and two copies genuinely made at different moments would tie differently on
/// each side. A UUID string is identical on both machines.
///
/// Items on a pinboard are never folded away. Folding one would silently
/// remove it from a board the user filed it on, and the membership rows point
/// at an id that no longer exists.
public func planDedup(_ items: [HistoryItem], pinned: Set<UUID> = []) -> [DedupPlan] {
    var groups: [String: [HistoryItem]] = [:]
    for item in items {
        // An empty hash would collapse every empty item into one group. Nothing
        // produces one today, but a future kind might.
        guard !item.contentHash.isEmpty else { continue }
        groups[item.contentHash, default: []].append(item)
    }

    return groups.values.compactMap { group -> DedupPlan? in
        guard group.count > 1 else { return nil }

        // A pinned item always survives. If two in a group are pinned, keep
        // both: folding either would break a board the user filed it on.
        let pinnedInGroup = group.filter { pinned.contains($0.id) }
        if pinnedInGroup.count > 1 { return nil }

        let survivor = pinnedInGroup.first
            ?? group.min { $0.id.uuidString < $1.id.uuidString }
        guard let survivor else { return nil }

        let doomed = group.filter { $0.id != survivor.id }.map(\.id)
        guard !doomed.isEmpty else { return nil }

        let newest = group.map(\.createdAt).max() ?? survivor.createdAt
        return DedupPlan(survivor: survivor.id, doomed: doomed, newestCreatedAt: newest)
    }
    // Stable order, so the same input always yields the same plan and two runs
    // can be compared.
    .sorted { $0.survivor.uuidString < $1.survivor.uuidString }
}
