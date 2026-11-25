import Foundation

public struct SyncRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let updatedAt: Date
    public let deletedAt: Date?
    public let deviceID: String

    public init(id: UUID, updatedAt: Date, deletedAt: Date?, deviceID: String) {
        self.id = id
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deviceID = deviceID
    }

    var isTombstone: Bool { deletedAt != nil }
}

public struct SyncManifest: Codable, Equatable, Sendable {
    public let deviceID: String
    public let records: [SyncRecord]
    /// Boards, merged by exactly the same rules as items.
    ///
    /// Defaulted so a manifest written by an older build still decodes. Failing
    /// to decode would strand the pair, each unable to read the other.
    public var boards: [SyncRecord] = []

    /// Which items are filed on which boards, as records of their own.
    ///
    /// Their own stream rather than a field inside each board, because one
    /// timestamp per board cannot say "I hold a filing you do not". Measured:
    /// with memberships carried inside the board payload, two Macs that each
    /// filed a different item onto the same board each kept only their own,
    /// forever. See BoardMembershipSyncTests.
    ///
    /// Defaulted for the same reason as `boards`.
    public var memberships: [SyncRecord] = []

    public init(deviceID: String, records: [SyncRecord], boards: [SyncRecord] = [],
                memberships: [SyncRecord] = []) {
        self.deviceID = deviceID
        self.records = records
        self.boards = boards
        self.memberships = memberships
    }

    /// Written by hand because Swift's synthesized Decodable does NOT fall back
    /// to a property's default value when the key is missing: it throws.
    ///
    /// Measured: a manifest from a build without boards failed to decode at all,
    /// which would strand a pair of Macs on different versions, each unable to
    /// read the other. decodeIfPresent is the whole fix.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        records = try container.decode([SyncRecord].self, forKey: .records)
        boards = try container.decodeIfPresent([SyncRecord].self, forKey: .boards) ?? []
        memberships = try container.decodeIfPresent([SyncRecord].self, forKey: .memberships) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case deviceID, records, boards, memberships
    }
}

public enum SyncAction: Equatable, Sendable {
    case upload(UUID)
    case download(UUID)
    case applyTombstone(UUID)
    case nothing(UUID)
}

/// Decides what each side owes the other. Pure, so every conflict case is
/// testable with no network and no database.
///
/// Last writer wins on `updatedAt`. Rejected: vector clocks, which are correct
/// for arbitrary topologies but are a great deal of machinery for two Macs
/// owned by one person, where a wall clock disagreement is measured in seconds.
public func planSync(local: [SyncRecord], remote: [SyncRecord]) -> [SyncAction] {
    var localByID = [UUID: SyncRecord]()
    for record in local { localByID[record.id] = record }
    // Several manifests can list the same item. Keep the NEWEST record, never
    // simply the last one listed. Manifests are listed in key order, so "last"
    // meant "the device whose id sorts last", and a device last seen in
    // September sorts after the live Mac: its two month old records replaced
    // the live ones. Measured in production as ten items re-uploaded on every
    // pass, and it also meant a deletion made on the live Mac could never
    // arrive while the stale manifest still said "live".
    let remoteByID = newestByID(remote)

    // Stable ordering: local first in their given order, then remote-only in
    // theirs. A plan that reorders between runs is impossible to compare.
    // Each id once: an item listed by two manifests used to be planned, and
    // fetched, twice.
    var order: [UUID] = local.map(\.id)
    var planned = Set(order)
    for record in remote where localByID[record.id] == nil && !planned.contains(record.id) {
        order.append(record.id)
        planned.insert(record.id)
    }

    return order.map { id in
        switch (localByID[id], remoteByID[id]) {
        case let (mine?, theirs?):
            // Both sides already hold a deletion: nothing to exchange, whatever
            // the timestamps say. This rule used to apply only on an exact tie,
            // so two tombstones a few seconds apart made each Mac re-apply the
            // other's on every pass, forever. Measured as "tombstones 26" on
            // every single pass in production.
            if mine.isTombstone && theirs.isTombstone { return .nothing(id) }
            if mine.updatedAt > theirs.updatedAt { return .upload(id) }
            if mine.updatedAt < theirs.updatedAt {
                // A tombstone needs no body. Downloading the content of a
                // deleted item is wasted, and for an image it is wasted
                // megabytes.
                return theirs.isTombstone ? .applyTombstone(id) : .download(id)
            }
            // Equal timestamps, and one side is a tombstone. The DELETE wins,
            // whichever side holds it.
            //
            // Measured, not predicted. Dedup stamped its tombstone with the
            // duplicate's own timestamp, which tied exactly with the live row on
            // the other Mac. The tie then fell through to the device id rule
            // below, which can only answer "nothing" or "download", so the
            // tombstone was dropped and the two Macs disagreed forever: one
            // showed the duplicate folded away, the other kept showing both.
            // The stamping is fixed too, but a tie can happen for other reasons
            // (the same millisecond, a re-imported row), and a rule that can
            // silently ignore a deletion is the wrong shape.
            //
            // This converges: the side holding the tombstone uploads it, the
            // side holding the live row applies it, and both land on deleted.
            if mine.isTombstone != theirs.isTombstone {
                return mine.isTombstone ? .upload(id) : .applyTombstone(id)
            }
            // Both sides already agree the item is gone, so there is nothing to
            // exchange. Without this the device id rule below answers "download"
            // for one of the two Macs, which re-fetches a deleted item on every
            // pass for the life of the app.
            if mine.isTombstone { return .nothing(id) }
            // Break the tie on device id so BOTH Macs reach the same answer.
            // Without this they disagree forever, each uploading over the other
            // on every pass.
            if mine.deviceID == theirs.deviceID { return .nothing(id) }
            return mine.deviceID > theirs.deviceID ? .nothing(id) : .download(id)
        case (.some, .none):
            return .upload(id)
        case (.none, let theirs?):
            return theirs.isTombstone ? .applyTombstone(id) : .download(id)
        case (.none, .none):
            return .nothing(id)
        }
    }
}

/// The newest record per item across every remote manifest. See planSync for
/// why "newest" and never "last listed". Public so the sync engine looks up the
/// exact record planSync decided on, for instance to stamp a received deletion
/// with the time it really happened.
public func newestByID(_ records: [SyncRecord]) -> [UUID: SyncRecord] {
    var out = [UUID: SyncRecord]()
    for record in records {
        if let held = out[record.id], !isNewer(record, than: held) { continue }
        out[record.id] = record
    }
    return out
}

/// Which of two records for the same item describes it more recently.
///
/// Later `updatedAt` wins. On a tie a deletion wins, the same rule planSync
/// applies between this Mac and the other. On a complete tie the device id
/// decides, only so that the answer never depends on the order the manifests
/// arrived in.
func isNewer(_ a: SyncRecord, than b: SyncRecord) -> Bool {
    if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
    if a.isTombstone != b.isTombstone { return a.isTombstone }
    return a.deviceID > b.deviceID
}
