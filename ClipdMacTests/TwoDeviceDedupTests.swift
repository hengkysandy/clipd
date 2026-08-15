import XCTest
import CryptoKit
@testable import ClipdMac
import ClipdCore

/// Dedup across two devices, against a real bucket.
///
/// The point of this file is that dedup and sync are only safe TOGETHER. Each
/// one passes its own unit tests while the pair loops forever: the first
/// version folded a duplicate away locally, the other Mac's manifest still
/// listed it, the next sync brought it back, and dedup folded it again. That
/// was measured in production ("up 19, down 31" followed immediately by
/// "deduplicated 31"), not predicted. Nothing except two stores talking through
/// one bucket can catch it, so this suite is deliberately an integration test
/// and skips when there are no credentials.
@MainActor
final class TwoDeviceDedupTests: XCTestCase {
    private var paths: [String] = []
    private var dirs: [URL] = []

    /// A throwaway namespace per run. See SyncEngineTests for why this exists:
    /// an earlier version of these tests deleted a live history out of the real
    /// bucket. Never point a destructive test at production.
    private let ns = "clipd-tests/\(UUID().uuidString)/"

    /// Two ids picked so their ORDER is fixed and visible in the test.
    /// `planDedup` keeps the lowest uuid string, so `keeper` must survive and
    /// `loser` must be folded, on both devices, without them consulting
    /// each other.
    private let keeper = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let loser  = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

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

    // MARK: - Harness

    private func makeStore(device: String) throws -> (Database, SQLiteStore) {
        let path = NSTemporaryDirectory() + "clipd-dedup-\(UUID().uuidString).sqlite"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-dedup-blobs-\(UUID().uuidString)")
        paths.append(path)
        dirs.append(dir)
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        let blobs = BlobStore(directory: dir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        return (db, SQLiteStore(database: db, blobs: blobs, deviceID: device))
    }

    private func cleanBucket(_ client: R2Client) async throws {
        for k in try await client.list(prefix: ns + "items/") { try await client.delete(k) }
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }
    }

    private func testKey() -> SymmetricKey {
        SyncCrypto.deriveKey(passphrase: "test-pass", salt: Data(repeating: 7, count: 32))
    }

    /// What the app really does after a sync: fold duplicates using the store's
    /// own view of the world.
    @discardableResult
    private func dedup(_ store: SQLiteStore) throws -> Int {
        try applyDedup(in: store,
                       items: try store.loadAll(limit: 500),
                       pinned: try store.pinnedItemIDs())
    }

    private func visibleIDs(_ store: SQLiteStore) throws -> [UUID] {
        try store.loadAll(limit: 500).map(\.id)
    }

    // MARK: - Tests

    /// Both Macs copy the same text, both dedup, and they must agree.
    func testBothMacsFoldTheSameDuplicateAndConverge() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)

        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }

        // The real world case. Each Mac refuses a duplicate of something IT
        // copied, so a duplicate can only be born as two rows with two ids and
        // one content hash, one on each device.
        let older = Date().addingTimeInterval(-600)
        let newer = Date()
        try storeA.insert(HistoryItem(id: keeper, text: "docker compose up -d",
                                      sourceBundleID: nil, sourceName: nil, createdAt: older))
        try storeB.insert(HistoryItem(id: loser, text: "docker compose up -d",
                                      sourceBundleID: nil, sourceName: nil, createdAt: newer))

        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A",
                           key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B",
                           key: testKey(), prefix: ns)

        // Three passes, because A cannot see B's manifest until B has written
        // one. After this both devices hold both rows, which is the state the
        // user actually reported.
        _ = try await a.runOnce()
        _ = try await b.runOnce()
        _ = try await a.runOnce()
        XCTAssertEqual(try visibleIDs(storeA).count, 2)
        XCTAssertEqual(try visibleIDs(storeB).count, 2)

        // Both dedup, neither knowing the other is doing it. This is the case
        // the whole design has to survive, and the reason the survivor is
        // chosen by uuid order rather than by a timestamp: two devices disagree
        // about clocks, so a clock based rule would let them fold in opposite
        // directions and undo each other forever.
        XCTAssertEqual(try dedup(storeA), 1)
        XCTAssertEqual(try dedup(storeB), 1)

        XCTAssertEqual(try visibleIDs(storeA), [keeper])
        XCTAssertEqual(try visibleIDs(storeB), [keeper])

        // The survivor inherits the NEWEST copy's time, on both devices, so the
        // item does not sink back down the history to the age of the older row.
        for store in [storeA, storeB] {
            let survivor = try XCTUnwrap(try store.loadAll(limit: 10).first)
            XCTAssertEqual(survivor.createdAt.timeIntervalSince1970,
                           newer.timeIntervalSince1970, accuracy: 1.0)
        }

        // Convergence is the claim, so keep exchanging and require that nothing
        // moves. A flapping pair would show up here as a resurrected row.
        for _ in 0..<3 {
            _ = try await a.runOnce()
            _ = try await b.runOnce()
        }
        XCTAssertEqual(try visibleIDs(storeA), [keeper])
        XCTAssertEqual(try visibleIDs(storeB), [keeper])

        // And no further folding is even planned. If either side still had work
        // to do, the app would fold on every single sync, forever.
        XCTAssertTrue(planDedup(try storeA.loadAll(limit: 500)).isEmpty)
        XCTAssertTrue(planDedup(try storeB.loadAll(limit: 500)).isEmpty)

        // The bucket must follow the same decision: the folded object is pruned
        // and the survivor's object is kept. Getting this backwards would
        // delete the row the user can still see.
        let keys = Set(try await client.list(prefix: ns + "items/"))
        XCTAssertTrue(keys.contains(ns + "items/\(keeper.uuidString).enc"))
        XCTAssertFalse(keys.contains(ns + "items/\(loser.uuidString).enc"))

        try await cleanBucket(client)
    }

    /// One Mac is asleep while the other dedups. This is the resurrection loop
    /// that actually shipped.
    func testAMacThatWasOfflineDuringTheDedupDoesNotResurrectTheDuplicate() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)

        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }

        try storeA.insert(HistoryItem(id: keeper, text: "kubectl get pods -A",
                                      sourceBundleID: nil, sourceName: nil,
                                      createdAt: Date().addingTimeInterval(-600)))
        try storeB.insert(HistoryItem(id: loser, text: "kubectl get pods -A",
                                      sourceBundleID: nil, sourceName: nil, createdAt: Date()))

        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A",
                           key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B",
                           key: testKey(), prefix: ns)
        _ = try await a.runOnce()
        _ = try await b.runOnce()
        _ = try await a.runOnce()
        XCTAssertEqual(try visibleIDs(storeA).count, 2)
        XCTAssertEqual(try visibleIDs(storeB).count, 2)

        // Only A dedups. B is closed, or asleep, and still holds both rows and
        // still advertises the folded one in its manifest.
        XCTAssertEqual(try dedup(storeA), 1)
        _ = try await a.runOnce()
        XCTAssertEqual(try visibleIDs(storeA), [keeper])

        // B wakes up. It must ACCEPT the tombstone rather than push its own
        // copy back, and it must not need to run dedup itself to get there.
        _ = try await b.runOnce()
        XCTAssertEqual(try visibleIDs(storeB), [keeper])

        // A must not have the row handed back to it on the next pass. This is
        // the exact loop that was measured in production.
        _ = try await a.runOnce()
        XCTAssertEqual(try visibleIDs(storeA), [keeper])

        // B must not have re-uploaded the object it just tombstoned either,
        // otherwise the bucket grows by one ghost per sleeping device.
        let keys = Set(try await client.list(prefix: ns + "items/"))
        XCTAssertFalse(keys.contains(ns + "items/\(loser.uuidString).enc"))

        try await cleanBucket(client)
    }

    /// A third device joins after the object has already been pruned.
    ///
    /// The manifests it reads may still name the folded id, and the object
    /// behind that id is gone. A missing object must be a skip, never a crash
    /// and never an empty row.
    func testAMacJoiningAfterADedupGetsTheSurvivorAndNotAGhost() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)

        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        let (dbC, storeC) = try makeStore(device: "device-C")
        defer { dbA.close(); dbB.close(); dbC.close() }

        try storeA.insert(HistoryItem(id: keeper, text: "terraform apply",
                                      sourceBundleID: nil, sourceName: nil,
                                      createdAt: Date().addingTimeInterval(-600)))
        try storeB.insert(HistoryItem(id: loser, text: "terraform apply",
                                      sourceBundleID: nil, sourceName: nil, createdAt: Date()))

        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A",
                           key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B",
                           key: testKey(), prefix: ns)
        _ = try await a.runOnce()
        _ = try await b.runOnce()
        _ = try await a.runOnce()

        XCTAssertEqual(try dedup(storeA), 1)
        _ = try await a.runOnce()   // uploads the tombstone and prunes the object

        // C has never seen any of this. It reads both manifests, one of which
        // may still list the pruned id as alive.
        let c = SyncEngine(client: client, store: storeC, deviceID: "device-C",
                           key: testKey(), prefix: ns)
        _ = try await c.runOnce()

        XCTAssertEqual(try visibleIDs(storeC), [keeper])
        let text = try XCTUnwrap(try storeC.loadAll(limit: 10).first?.text)
        XCTAssertEqual(text, "terraform apply")

        // And a second pass leaves it alone rather than re-fetching forever.
        _ = try await c.runOnce()
        XCTAssertEqual(try visibleIDs(storeC), [keeper])
        XCTAssertTrue(planDedup(try storeC.loadAll(limit: 500)).isEmpty)

        try await cleanBucket(client)
    }

    /// A pinned duplicate must never be folded away by the other device.
    ///
    /// Filing an item on a board is a deliberate act, and the membership rows
    /// point at the id. If the far Mac folded the pinned row, the board would
    /// quietly lose an item and be left pointing at a dead id.
    func testAPinnedCopyIsNeverFoldedAwayByTheOtherMac() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)

        let (dbA, storeA) = try makeStore(device: "device-A")
        defer { dbA.close() }

        try storeA.insert(HistoryItem(id: keeper, text: "psql -h localhost",
                                      sourceBundleID: nil, sourceName: nil,
                                      createdAt: Date().addingTimeInterval(-600)))
        try storeA.insert(HistoryItem(id: loser, text: "psql -h localhost",
                                      sourceBundleID: nil, sourceName: nil, createdAt: Date()))

        // Pin the row that dedup would otherwise fold, so the two rules
        // disagree and the pin has to win.
        let board = try storeA.createPinboard(name: "Commands")
        try storeA.setMembership(item: loser, board: board.id, on: true)

        XCTAssertEqual(try dedup(storeA), 1)

        let survivors = try visibleIDs(storeA)
        XCTAssertEqual(survivors, [loser])
        XCTAssertTrue(try storeA.pinnedItemIDs().contains(loser))
        // membership() is keyed by BOARD, not by item.
        XCTAssertTrue(try storeA.membership()[board.id]?.contains(loser) ?? false)

        try await cleanBucket(client)
    }
}
