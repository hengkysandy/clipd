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

    init(client: R2Client, store: SQLiteStore, deviceID: String,
         key: SymmetricKey, prefix: String = "") {
        self.client = client
        self.store = store
        self.deviceID = deviceID
        self.key = key
        self.prefix = prefix
    }

    func runOnce() async throws -> SyncSummary {
        let local = try store.allRecords()

        // Every manifest except our own. Ours describes what we already know.
        var remote: [SyncRecord] = []
        for manifestKey in try await client.list(prefix: prefix + "manifests/")
        where !manifestKey.hasSuffix("\(deviceID).json.enc") {
            guard let sealed = try await client.get(manifestKey) else { continue }
            do {
                let plain = try SyncCrypto.open(sealed, with: key)
                remote.append(contentsOf: try JSONDecoder().decode(SyncManifest.self, from: plain).records)
            } catch {
                // A manifest we cannot decrypt means a different passphrase.
                // Skipping is right: overwriting it would destroy the other
                // Mac's index, and failing the whole pass would strand us.
                Diag.sync.error("skipping an undecryptable manifest")
            }
        }

        var uploaded = 0, downloaded = 0, tombstoned = 0, pruned = 0

        for action in planSync(local: local, remote: remote) {
            switch action {
            case .upload(let id):
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
                try store.applyTombstone(id: id, at: Date())
                tombstoned += 1

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
        var remoteBoards: [SyncRecord] = []
        for manifestKey in try await client.list(prefix: prefix + "manifests/")
        where !manifestKey.hasSuffix("\(deviceID).json.enc") {
            guard let sealed = try await client.get(manifestKey),
                  let plain = try? SyncCrypto.open(sealed, with: key),
                  let manifest = try? JSONDecoder().decode(SyncManifest.self, from: plain)
            else { continue }
            remoteBoards.append(contentsOf: manifest.boards)
        }

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

        // Our manifest last, so it only ever claims things we really uploaded.
        let manifest = SyncManifest(deviceID: deviceID,
                                    records: try store.allRecords(),
                                    boards: try store.boardRecords())
        let sealed = try SyncCrypto.seal(try JSONEncoder().encode(manifest), with: key)
        _ = try await client.put(prefix + "manifests/\(deviceID).json.enc", sealed)

        return SyncSummary(uploaded: uploaded, downloaded: downloaded,
                           tombstoned: tombstoned, pruned: pruned)
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
