import Foundation
import CryptoKit
import ClipdCore

struct SyncSummary: Equatable {
    let uploaded: Int
    let downloaded: Int
    let tombstoned: Int
    /// Objects removed from the bucket this pass, because their item is
    /// tombstoned locally.
    let pruned: Int
    /// New copies kept off the bucket this pass because they are younger than
    /// the hold. The caller schedules a follow up pass for them.
    var heldBack: Int = 0
}

/// One sync pass.
///
/// Each device writes only its OWN manifest. Rejected: a single shared
/// manifest, which both Macs would write, making every pass a lost update race.
/// With one manifest each, the only shared keys are item objects, and those are
/// resolved by last writer wins on updatedAt.
///
/// Main actor isolated, not its own actor. SQLiteStore is also touched by the
/// capture path on the main actor, so a separate actor here would let a copy
/// arriving mid sync race the store. Rejected: marking SQLiteStore
/// @unchecked Sendable, which would be a false claim. Network calls still
/// suspend, so the UI is not blocked while requests are in flight.
@MainActor
final class SyncEngine {
    private let client: R2Client
    private let store: SQLiteStore
    private let deviceID: String
    private let key: SymmetricKey
    /// Everything this engine touches lives under here.
    ///
    /// Exists so tests can be given a throwaway namespace. They previously ran
    /// against the real "items/" and "manifests/" paths and deleted a live
    /// history from the bucket as cleanup. Nothing was permanently lost because
    /// each Mac keeps its own copy, but a second device then synced against an
    /// empty bucket and looked broken. Never point a destructive test at
    /// production.
    private let prefix: String
    /// How long a new copy made on this Mac waits before it may leave it.
    ///
    /// The auto-clear window when auto-clear is on, zero when it is off. A
    /// copy inside the hold is neither uploaded nor listed in this Mac's
    /// manifest, so if the auto-clear rule then catches it as a secret, no
    /// byte of it, and no record of it, ever reached the bucket or the other
    /// Mac. Everything else (deletes, filings, renames, boards, anything that
    /// arrived from the other Mac) is never held.
    private let holdBack: TimeInterval
    /// Injectable so a test can let the hold expire without waiting 90 seconds.
    private let now: () -> Date

    init(client: R2Client, store: SQLiteStore, deviceID: String,
         key: SymmetricKey, prefix: String = "",
         holdBack: TimeInterval = 0, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.store = store
        self.deviceID = deviceID
        self.key = key
        self.prefix = prefix
        self.holdBack = holdBack
        self.now = now
    }

    private func heldBackIDs() throws -> Set<UUID> {
        guard holdBack > 0 else { return [] }
        return try store.idsCapturedHere(since: now().addingTimeInterval(-holdBack))
    }

    func runOnce() async throws -> SyncSummary {
        let held = try heldBackIDs()
        let local = try store.allRecords().filter { !held.contains($0.id) }

        // Every manifest except our own. Ours describes what we already know.
        //
        // Read ONCE and reused for items, boards and memberships below. This
        // used to be a separate list-and-get pass per record type, which was
        // three times the R2 requests for exactly the same bytes.
        var remoteManifests: [SyncManifest] = []
        for manifestKey in try await client.list(prefix: prefix + "manifests/")
        where !manifestKey.hasSuffix("\(deviceID).json.enc") {
            guard let sealed = try await client.get(manifestKey) else { continue }
            do {
                let plain = try SyncCrypto.open(sealed, with: key)
                remoteManifests.append(try JSONDecoder().decode(SyncManifest.self, from: plain))
            } catch {
                // A manifest we cannot decrypt means a different passphrase.
                // Skipping is right: overwriting it would destroy the other
                // Mac's index, and failing the whole pass would strand us.
                Diag.sync.error("skipping an undecryptable manifest")
            }
        }
        let remote = remoteManifests.flatMap(\.records)

        var uploaded = 0, downloaded = 0, tombstoned = 0, pruned = 0

        // An item's deletion travels in this Mac's manifest, never as an
        // object. Nobody ever downloads an item tombstone's body:
        // `.applyTombstone` below needs only the record. Uploading one did
        // harm: the prune step further down deletes it again in the same pass,
        // and a Mac that never had the item has no row to mark, so it never
        // lists the tombstone, so planSync asks for the upload again next pass,
        // forever. Measured in production as "up 378 ... pruned 370" on passes
        // that took about seven minutes. Boards and memberships are different
        // and still upload theirs: their tombstones are applied from the body.
        let tombstonedHere = Set(local.filter { $0.deletedAt != nil }.map(\.id))
        // The exact remote record planSync chose, per item.
        let remoteNewest = newestByID(remote)

        for action in planSync(local: local, remote: remote) {
            switch action {
            case .upload(let id):
                if tombstonedHere.contains(id) { continue }
                guard let payload = try store.payload(for: id) else { continue }
                let sealed = try SyncCrypto.seal(payload, with: key)
                _ = try await client.put(prefix + "items/\(id.uuidString).enc", sealed)
                uploaded += 1

            case .download(let id):
                guard let sealed = try await client.get(prefix + "items/\(id.uuidString).enc") else { continue }
                do {
                    try store.apply(payload: try SyncCrypto.open(sealed, with: key))
                    downloaded += 1
                } catch let error as PayloadFormatError {
                    // Skip the object, finish the pass. Rejected: letting this
                    // throw, which is what it did when the payload format grew a
                    // version header. One object written by a newer Clipd would
                    // then abort the whole sync, so this Mac would stop syncing
                    // EVERYTHING until the other Mac was downgraded. The same
                    // reasoning as the undecryptable manifest above: one bad
                    // object must cost one item, not the session.
                    switch error {
                    case .newerVersion(let v):
                        Diag.sync.error("skipping an item written by a newer version of Clipd (format \(v, privacy: .public)), update this Mac")
                    case .malformed(let reason):
                        Diag.sync.error("skipping a corrupt item payload: \(reason, privacy: .public)")
                    }
                }

            case .applyTombstone(let id):
                // Stamped with when the other Mac really deleted it, not with
                // now. A later stamp would make this Mac's copy look newer than
                // the other's, and would let a deletion beat an edit that the
                // other Mac made after deleting.
                let when = remoteNewest[id]?.deletedAt ?? Date()
                if try store.applyTombstone(id: id, at: when) { tombstoned += 1 }

            case .nothing:
                break
            }
        }

        // Prune the objects behind items we have deleted. A tombstone alone only
        // hides the row, so without this the bucket grows forever, and an image
        // costs megabytes per deleted item.
        //
        // The decision to prune an id comes from OUR OWN local records and
        // nothing else. Rejected: pruning from a remote manifest, or from the
        // merged view of all manifests. A device that has not yet learned about
        // an item has no record for it at all, so a manifest driven rule would
        // let one device delete the object out from under another device that
        // still needs to download it. Reading our own tombstones can only ever
        // delete something we ourselves already decided is gone.
        //
        // Re-read rather than reuse `local`: the loop above may have just
        // applied tombstones that arrived from the other Mac, and those objects
        // are exactly the ones worth pruning this pass.
        let doomed = Set(try store.allRecords()
            .filter { $0.deletedAt != nil }
            .map { prefix + "items/\($0.id.uuidString).enc" })

        // Listing first, then deleting only the keys that are really there, so a
        // pass costs one LIST instead of one DELETE per tombstone. Tombstones are
        // permanent, so the naive version would re-delete every item we have ever
        // deleted, on every pass, forever. The listing only narrows the work: an
        // id still has to be in `doomed` to be touched.
        for key in try await client.list(prefix: prefix + "items/") where doomed.contains(key) {
            // try? so one failed delete does not abort the pass. The object
            // stays, and the next pass retries it, because the tombstone that
            // condemned it is permanent.
            try? await client.delete(key)
            pruned += 1
        }
        Diag.sync.info("pruned \(pruned, privacy: .public) bucket objects for tombstoned items")

        // Boards, by exactly the same rules. Kept separate from items so a
        // board can never be mistaken for a clipping.
        let remoteBoards = remoteManifests.flatMap(\.boards)

        for action in planSync(local: try store.boardRecords(), remote: remoteBoards) {
            switch action {
            case .upload(let id):
                guard let payload = try store.boardPayload(for: id) else { continue }
                _ = try await client.put(prefix + "boards/\(id.uuidString).enc",
                                         try SyncCrypto.seal(payload, with: key))
            case .download(let id), .applyTombstone(let id):
                // Even a tombstoned board needs its payload: the row carries the
                // deleted_at that makes it a tombstone locally.
                guard let sealed = try await client.get(prefix + "boards/\(id.uuidString).enc")
                else { continue }
                try store.applyBoard(payload: try SyncCrypto.open(sealed, with: key))
            case .nothing:
                break
            }
        }

        // Memberships, by the same rules again, and as their own records
        // rather than a field inside each board.
        //
        // Measured before this existed: a board's own updated_at never moved
        // when an item was filed onto it, so planSync saw no change and the
        // filing never left the Mac that made it. Bumping the board's
        // timestamp would not have been enough either, because one timestamp
        // per board cannot say "I hold a filing you do not", and two Macs that
        // each filed a different item onto the same board each kept only their
        // own. Both cases are in BoardMembershipSyncTests.
        let remoteMemberships = remoteManifests.flatMap(\.memberships)

        for action in planSync(local: try store.membershipRecords(),
                               remote: remoteMemberships) {
            switch action {
            case .upload(let id):
                guard let payload = try store.membershipPayload(for: id) else { continue }
                _ = try await client.put(prefix + "memberships/\(id.uuidString).enc",
                                         try SyncCrypto.seal(payload, with: key))
            case .download(let id), .applyTombstone(let id):
                // A tombstoned filing still needs its row: the deleted_at on it
                // is what un-files the item on this Mac.
                guard let sealed = try await client.get(prefix + "memberships/\(id.uuidString).enc")
                else { continue }
                try store.applyMembership(payload: try SyncCrypto.open(sealed, with: key))
            case .nothing:
                break
            }
        }

        // Our manifest last, so it only ever claims things we really uploaded.
        //
        // The hold is worked out AGAIN here, not reused from the start of the
        // pass. A first pass can take minutes, and a copy made while it ran is
        // in `allRecords()` now but was never considered for upload, so
        // without this it would be claimed here without being uploaded.
        let heldAtEnd = try heldBackIDs()
        let manifest = SyncManifest(deviceID: deviceID,
                                    records: try store.allRecords().filter { !heldAtEnd.contains($0.id) },
                                    boards: try store.boardRecords(),
                                    memberships: try store.membershipRecords())
        let sealed = try SyncCrypto.seal(try JSONEncoder().encode(manifest), with: key)
        _ = try await client.put(prefix + "manifests/\(deviceID).json.enc", sealed)

        return SyncSummary(uploaded: uploaded, downloaded: downloaded,
                           tombstoned: tombstoned, pruned: pruned,
                           heldBack: heldAtEnd.count)
    }

    /// Fetches the shared salt, creating it once if this is the first device.
    ///
    /// If-None-Match makes the create atomic, so two Macs setting up at the
    /// same moment cannot end up with different salts and therefore different
    /// keys. Measured on R2: the second write returns 412.
    static func fetchOrCreateSalt(client: R2Client, prefix: String = "") async throws -> Data {
        if let existing = try await client.get(prefix + "salt.bin") { return existing }
        let fresh = SyncCrypto.randomSalt()
        let created = try await client.put(prefix + "salt.bin", fresh, ifAbsent: true)
        if created { return fresh }
        guard let theirs = try await client.get(prefix + "salt.bin") else {
            throw R2Error.transport("salt vanished after a losing create")
        }
        return theirs
    }
}
