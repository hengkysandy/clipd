import XCTest
import CryptoKit
@testable import ClipdMac
import ClipdCore

/// New copies wait out the auto-clear window before they may leave the Mac.
///
/// Before this, a capture synced 15 seconds after the copy and Passwords.app
/// wiped the clipboard at 60, so every secret the auto-clear rule caught had
/// already been uploaded and copied to the other Mac. Against a real bucket,
/// because the guarantee is about what the bucket and the other Mac receive.
@MainActor
final class HoldBackSyncTests: XCTestCase {
    private var paths: [String] = []
    private var dirs: [URL] = []
    private let ns = "clipd-tests/\(UUID().uuidString)/"
    /// The engines read the time from here, so a test can let the hold pass.
    private var clock = Date()

    func testTheTestNamespaceIsNeverTheProductionOne() {
        XCTAssertTrue(ns.hasPrefix("clipd-tests/"))
        XCTAssertFalse(ns.hasPrefix("items/"))
    }

    override func tearDown() async throws {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        try await super.tearDown()
    }

    private func makeStore(device: String) throws -> (Database, SQLiteStore) {
        let path = NSTemporaryDirectory() + "clipd-hold-\(UUID().uuidString).sqlite"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-hold-blobs-\(UUID().uuidString)")
        paths.append(path)
        dirs.append(dir)
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        let blobs = BlobStore(directory: dir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        return (db, SQLiteStore(database: db, blobs: blobs, deviceID: device))
    }

    private func key() -> SymmetricKey {
        SyncCrypto.deriveKey(passphrase: "test-pass", salt: Data(repeating: 7, count: 32))
    }

    private struct Pair {
        let client: R2Client
        let dbA: Database, storeA: SQLiteStore, a: SyncEngine
        let dbB: Database, storeB: SQLiteStore, b: SyncEngine
    }

    /// Both Macs hold, exactly as the app runs them with auto-clear on.
    private func pair() async throws -> Pair {
        guard let creds = R2ClientTests.loadCredentialsForTests() else { throw XCTSkip("no .env.local") }
        let client = R2Client(credentials: creds)
        for part in ["items/", "boards/", "memberships/", "manifests/"] {
            for k in try await client.list(prefix: ns + part) { try await client.delete(k) }
        }
        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        let now = { [unowned self] in self.clock }
        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A", key: key(),
                           prefix: ns, holdBack: autoClearWindow, now: now)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B", key: key(),
                           prefix: ns, holdBack: autoClearWindow, now: now)
        return Pair(client: client, dbA: dbA, storeA: storeA, a: a, dbB: dbB, storeB: storeB, b: b)
    }

    private func settle(_ p: Pair) async throws {
        _ = try await p.a.runOnce()
        _ = try await p.b.runOnce()
        _ = try await p.a.runOnce()
        _ = try await p.b.runOnce()
    }

    private func ids(_ store: SQLiteStore) throws -> [UUID] { try store.loadAll(limit: 500).map(\.id) }

    private func manifestOfA(_ p: Pair) async throws -> SyncManifest? {
        guard let sealed = try await p.client.get(ns + "manifests/device-A.json.enc") else { return nil }
        return try JSONDecoder().decode(SyncManifest.self, from: SyncCrypto.open(sealed, with: key()))
    }

    func testANewCopyIsNeitherUploadedNorListedInsideTheHold() async throws {
        let p = try await pair()
        defer { p.dbA.close(); p.dbB.close() }
        let fresh = HistoryItem(text: "just copied", sourceBundleID: nil, sourceName: nil, createdAt: clock)
        try p.storeA.insert(fresh)

        let summary = try await p.a.runOnce()
        XCTAssertEqual(summary.heldBack, 1)
        let object = try await p.client.get(ns + "items/\(fresh.id.uuidString).enc")
        XCTAssertNil(object, "a copy inside the hold must not be uploaded")
        let listed = try await manifestOfA(p)?.records.map(\.id) ?? []
        XCTAssertFalse(listed.contains(fresh.id), "nor even listed, or the other Mac learns it exists")

        try await settle(p)
        XCTAssertEqual(try ids(p.storeB), [], "the other Mac must not have it yet")
    }

    func testAHeldCopyGoesUpOnceTheHoldHasPassed() async throws {
        let p = try await pair()
        defer { p.dbA.close(); p.dbB.close() }
        let fresh = HistoryItem(text: "ordinary copy", sourceBundleID: nil, sourceName: nil, createdAt: clock)
        try p.storeA.insert(fresh)
        try await settle(p)
        XCTAssertEqual(try ids(p.storeB), [])

        clock = clock.addingTimeInterval(autoClearWindow + 5)
        try await settle(p)
        XCTAssertEqual(try ids(p.storeB), [fresh.id], "an ordinary copy must still arrive, just later")
    }

    /// The point of the whole change.
    func testASecretCaughtInsideTheHoldNeverReachesTheBucketOrTheOtherMac() async throws {
        let p = try await pair()
        defer { p.dbA.close(); p.dbB.close() }
        let marker = "hunter2-\(UUID().uuidString)"
        let secret = HistoryItem(text: marker, sourceBundleID: nil, sourceName: nil, createdAt: clock)
        try p.storeA.insert(secret)
        try await settle(p)                          // syncs while the secret is fresh

        clock = clock.addingTimeInterval(60)         // Passwords.app wipes at 60s
        try p.storeA.scrubSecret(id: secret.id)
        try await settle(p)

        clock = clock.addingTimeInterval(autoClearWindow)  // and long after
        try await settle(p)

        XCTAssertEqual(try ids(p.storeA), [])
        XCTAssertEqual(try ids(p.storeB), [], "the other Mac must never have had it")
        let rows = try p.dbB.query("SELECT COUNT(*) AS n FROM items WHERE id = ?",
                                   [.text(secret.id.uuidString)])
        XCTAssertEqual(rows.first?["n"], .int(0), "not even as a row on the other Mac")
        for k in try await p.client.list(prefix: ns + "items/") {
            guard let sealed = try await p.client.get(k) else { continue }
            let plain = try SyncCrypto.open(sealed, with: key())
            XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains(marker),
                           "no object in the bucket may ever hold the secret")
        }
    }

    /// The hold is for new copies only. A delete must reach the other Mac on
    /// the very next pass, even while a fresh copy is being held.
    func testDeletesAreNeverHeld() async throws {
        let p = try await pair()
        defer { p.dbA.close(); p.dbB.close() }
        let old = HistoryItem(text: "copied ten minutes ago", sourceBundleID: nil, sourceName: nil,
                              createdAt: clock.addingTimeInterval(-600))
        try p.storeA.insert(old)
        try await settle(p)
        XCTAssertEqual(try ids(p.storeB), [old.id], "baseline: the old item is not held")

        let fresh = HistoryItem(text: "fresh", sourceBundleID: nil, sourceName: nil, createdAt: clock)
        try p.storeA.insert(fresh)
        try p.storeA.deleteItem(id: old.id)
        try await settle(p)

        XCTAssertEqual(try ids(p.storeB), [], "the delete arrived; the fresh copy is still held")
    }
}
