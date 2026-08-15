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

    public init(deviceID: String, records: [SyncRecord]) {
        self.deviceID = deviceID
        self.records = records
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
    var remoteByID = [UUID: SyncRecord]()
    for record in remote { remoteByID[record.id] = record }

    // Stable ordering: local first in their given order, then remote-only in
    // theirs. A plan that reorders between runs is impossible to compare.
    var order: [UUID] = local.map(\.id)
    for record in remote where localByID[record.id] == nil { order.append(record.id) }

    return order.map { id in
        switch (localByID[id], remoteByID[id]) {
        case let (mine?, theirs?):
            if mine.updatedAt > theirs.updatedAt { return .upload(id) }
            if mine.updatedAt < theirs.updatedAt {
                // A tombstone needs no body. Downloading the content of a
                // deleted item is wasted, and for an image it is wasted
                // megabytes.
                return theirs.isTombstone ? .applyTombstone(id) : .download(id)
            }
            // Equal timestamps. Break the tie on device id so BOTH Macs reach
            // the same answer. Without this they disagree forever, each
            // uploading over the other on every pass.
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
