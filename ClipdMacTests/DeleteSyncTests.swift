import XCTest
import CryptoKit
@testable import ClipdMac
import ClipdCore

/// Deleting, across two Macs, against a real bucket.
///
/// Every older sync test deleted with `softDelete`, the tombstone, and passed.
/// The app's Delete key was wired to `hardDelete` instead, which removes the
/// row outright. No test went through the app's wiring, so nothing noticed.
/// These call the same store methods the app calls.
@MainActor
final class DeleteSyncTests: XCTestCase {
    private var paths: [String] = []
    private var dirs: [URL] = []
    private let ns = "clipd-tests/\(UUID().uuidString)/"

    func testTheTestNamespaceIsNeverTheProductionOne() {
        XCTAssertTrue(ns.hasPrefix("clipd-tests/"))
        XCTAssertFalse(ns.hasPrefix("items/"))
        XCTAssertFalse(ns.hasPrefix("manifests/"))
    }

    override func tearDown() async throws {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        try await super.tearDown()
    }

    private func makeStore(device: String) throws -> (Database, SQLiteStore) {
        let path = NSTemporaryDirectory() + "clipd-del-\(UUID().uuidString).sqlite"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-del-blobs-\(UUID().uuidString)")
        paths.append(path)
        dirs.append(dir)
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        let blobs = BlobStore(directory: dir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        return (db, SQLiteStore(database: db, blobs: blobs, deviceID: device))
    }

    private func cleanBucket(_ client: R2Client) async throws {
        for part in ["items/", "boards/", "memberships/", "manifests/"] {
            for k in try await client.list(prefix: ns + part) { try await client.delete(k) }
        }
    }

    private func testKey() -> SymmetricKey {
        SyncCrypto.deriveKey(passphrase: "test-pass", salt: Data(repeating: 7, count: 32))
    }

    private func settle(_ a: SyncEngine, _ b: SyncEngine) async throws {
        _ = try await a.runOnce()
        _ = try await b.runOnce()
        _ = try await a.runOnce()
        _ = try await b.runOnce()
    }

    private func ids(_ store: SQLiteStore) throws -> [UUID] { try store.loadAll(limit: 500).map(\.id) }

    /// The Delete key. Delete on A, and it must be gone on BOTH Macs and stay
    /// gone, rather than come back from B on the next pass.
    func testADeletedItemStaysDeletedOnBothMacs() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else { throw XCTSkip("no .env.local") }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)
        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }
        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A", key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B", key: testKey(), prefix: ns)

        let item = HistoryItem(text: "delete me everywhere", sourceBundleID: nil,
                               sourceName: nil, createdAt: Date())
        try storeA.insert(item)
        try await settle(a, b)
        XCTAssertEqual(try ids(storeB), [item.id], "baseline: it reached B")

        try storeA.deleteItem(id: item.id)
        try await settle(a, b)

        XCTAssertEqual(try ids(storeA), [], "must not come back on A from B")
        XCTAssertEqual(try ids(storeB), [], "must be deleted on B too")
    }

    /// Once both Macs agree an item is deleted, they must stop talking about
    /// it. A received deletion used to be stamped with the time it was
    /// APPLIED, so each Mac's copy looked newer than the other's, and each pass
    /// re-applied it on the other side, forever. Seen in production as
    /// "tombstones 26" on every single pass.
    func testAnAgreedDeletionGoesQuiet() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else { throw XCTSkip("no .env.local") }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)
        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }
        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A", key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B", key: testKey(), prefix: ns)

        let item = HistoryItem(text: "deleted once", sourceBundleID: nil, sourceName: nil, createdAt: Date())
        try storeA.insert(item)
        try await settle(a, b)
        try storeA.deleteItem(id: item.id)
        try await settle(a, b)
        XCTAssertEqual(try ids(storeB), [], "baseline: the deletion arrived")

        for pass in 1...2 {
            let sa = try await a.runOnce()
            let sb = try await b.runOnce()
            XCTAssertEqual(sa.tombstoned + sb.tombstoned, 0, "pass \(pass): an agreed deletion was applied again")
            XCTAssertEqual(sa.uploaded + sb.uploaded, 0, "pass \(pass): something was re-sent")
            XCTAssertEqual(sa.downloaded + sb.downloaded, 0, "pass \(pass): something was re-fetched")
        }
    }

    /// A deletion the other Mac never needs must not be re-sent forever.
    ///
    /// Measured in production: passes reporting "up 378 ... pruned 370" and
    /// taking about seven minutes. A tombstone for an item the other Mac never
    /// had was uploaded as an object, then pruned by the same pass, and the
    /// other Mac, having no row to mark, never listed it, so the next pass did
    /// it all again. Steady state must be zero traffic.
    func testADeletionTheOtherMacNeverHadIsNotResentEveryPass() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else { throw XCTSkip("no .env.local") }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)
        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }
        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A", key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B", key: testKey(), prefix: ns)

        // Copied and deleted on A before B ever saw it.
        let item = HistoryItem(text: "gone before it travelled", sourceBundleID: nil,
                               sourceName: nil, createdAt: Date())
        try storeA.insert(item)
        try storeA.deleteItem(id: item.id)
        try await settle(a, b)

        let again = try await a.runOnce()
        XCTAssertEqual(again.uploaded, 0, "nothing new happened, so nothing may be uploaded")
        XCTAssertEqual(again.pruned, 0, "and nothing may need pruning")
        XCTAssertEqual(try ids(storeB), [], "and B must still not have it")
    }

    /// The auto-clear rule. A capture syncs 15 seconds after the copy and
    /// Passwords.app wipes the clipboard at 60, so by the time a secret is
    /// caught it has ALREADY reached the bucket and the other Mac. Catching it
    /// must take it off both, and must leave no copy of the text anywhere.
    func testACaughtSecretIsRemovedFromBothMacsAndTheBucket() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else { throw XCTSkip("no .env.local") }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)
        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }
        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A", key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B", key: testKey(), prefix: ns)

        let marker = "hunter2-\(UUID().uuidString)"
        let secret = HistoryItem(text: marker, sourceBundleID: nil, sourceName: nil, createdAt: Date())
        try storeA.insert(secret)
        try await settle(a, b)
        XCTAssertEqual(try ids(storeB), [secret.id], "baseline: the secret reached B, as it does in real use")

        try storeA.scrubSecret(id: secret.id)
        try await settle(a, b)

        XCTAssertEqual(try ids(storeA), [], "must not come back on A")
        XCTAssertEqual(try ids(storeB), [], "must be gone from B")
        for (label, db) in [("A", dbA), ("B", dbB)] {
            let rows = try db.query("""
                SELECT COUNT(*) AS n FROM items
                WHERE text_content LIKE ? OR preview LIKE ? OR content_hash LIKE ?
                """, [.text("%\(marker)%"), .text("%\(marker)%"), .text("%\(marker)%")])
            if case .int(let n)? = rows.first?["n"] {
                XCTAssertEqual(n, 0, "no copy of the secret text may survive on \(label), even in a tombstone")
            }
        }
        // Whatever is left in the bucket for it must not decrypt to the text.
        if let sealed = try await client.get(ns + "items/\(secret.id.uuidString).enc") {
            let plain = try SyncCrypto.open(sealed, with: testKey())
            XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains(marker),
                           "the bucket object must not still hold the secret")
        }
    }
}
