import XCTest
import CryptoKit
@testable import ClipdMac
import ClipdCore

/// Filing an item onto a pinboard, across two Macs, against a real bucket.
///
/// Reported from production: boards themselves appear on both Macs, but what
/// you filed onto them does not. Nothing except two stores talking through one
/// bucket can show that, so this is an integration test and skips without
/// credentials.
@MainActor
final class BoardMembershipSyncTests: XCTestCase {
    private var paths: [String] = []
    private var dirs: [URL] = []

    /// A throwaway namespace per run. Never point a destructive test at the
    /// production prefixes.
    private let ns = "clipd-tests/\(UUID().uuidString)/"

    func testTheTestNamespaceIsNeverTheProductionOne() {
        XCTAssertTrue(ns.hasPrefix("clipd-tests/"))
        XCTAssertFalse(ns.hasPrefix("items/"))
        XCTAssertFalse(ns.hasPrefix("boards/"))
        XCTAssertFalse(ns.hasPrefix("memberships/"))
        XCTAssertFalse(ns.hasPrefix("manifests/"))
    }

    override func tearDown() async throws {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        try await super.tearDown()
    }

    private func makeStore(device: String) throws -> (Database, SQLiteStore) {
        let path = NSTemporaryDirectory() + "clipd-board-\(UUID().uuidString).sqlite"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-board-blobs-\(UUID().uuidString)")
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

    /// Three passes, because A cannot see B's manifest until B has written one.
    private func settle(_ a: SyncEngine, _ b: SyncEngine) async throws {
        _ = try await a.runOnce()
        _ = try await b.runOnce()
        _ = try await a.runOnce()
        _ = try await b.runOnce()
    }

    /// The reported bug, reduced to its smallest form.
    func testFilingAnItemOntoABoardReachesTheOtherMac() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)

        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }

        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A",
                           key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B",
                           key: testKey(), prefix: ns)

        // A makes a board and copies something, then both Macs catch up.
        let item = UUID()
        try storeA.insert(HistoryItem(id: item, text: "terraform plan",
                                      sourceBundleID: nil, sourceName: nil, createdAt: Date()))
        let board = try storeA.createPinboard(name: "infra")
        try await settle(a, b)

        // Baseline: the board and the item both travelled. If either of these
        // fails the bug is somewhere else entirely and the rest is noise.
        XCTAssertEqual(try storeB.allPinboards().map(\.id), [board.id],
                       "the board itself must reach the other Mac")
        XCTAssertEqual(try storeB.loadAll(limit: 10).map(\.id), [item],
                       "the item itself must reach the other Mac")

        // Now file the item onto the board. This is the action that is
        // reported as not syncing.
        try storeA.setMembership(item: item, board: board.id, on: true)
        XCTAssertEqual(try storeA.membership()[board.id], [item],
                       "sanity: it is filed locally on A")

        try await settle(a, b)

        XCTAssertEqual(try storeB.membership()[board.id], [item],
                       "filing an item onto a board must reach the other Mac")
    }

    /// Un-filing has to travel too. A tombstone that stays home means the item
    /// reappears on the board on the other Mac and nothing explains why.
    func testUnfilingAnItemAlsoReachesTheOtherMac() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)

        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }

        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A",
                           key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B",
                           key: testKey(), prefix: ns)

        let item = UUID()
        try storeA.insert(HistoryItem(id: item, text: "helm upgrade",
                                      sourceBundleID: nil, sourceName: nil, createdAt: Date()))
        let board = try storeA.createPinboard(name: "charts")
        try storeA.setMembership(item: item, board: board.id, on: true)
        try await settle(a, b)
        XCTAssertEqual(try storeB.membership()[board.id], [item], "baseline: it arrived")

        // Now take it off the board on A.
        try storeA.setMembership(item: item, board: board.id, on: false)
        try await settle(a, b)

        XCTAssertNil(try storeB.membership()[board.id],
                     "un-filing must reach the other Mac too")
    }

    /// The second defect found while tracing the first. The old board payload
    /// used INSERT OR REPLACE with no timestamp comparison, so a stale copy
    /// could un-file something that had just been filed here. No network
    /// needed to show it.
    func testAStaleMembershipNeverBeatsANewerLocalOne() throws {
        let (db, store) = try makeStore(device: "device-A")
        defer { db.close() }

        let item = UUID(), board = UUID()
        try store.setMembership(item: item, board: board, on: true)
        XCTAssertEqual(try store.membership()[board], [item])

        // A payload from the past saying the item was taken off the board.
        let old = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let stale = try JSONSerialization.data(withJSONObject: [
            "item_id": item.uuidString,
            "pinboard_id": board.uuidString,
            "updated_at": old,
            "deleted_at": old,
            "device_id": "device-B",
        ])
        try store.applyMembership(payload: stale)

        XCTAssertEqual(try store.membership()[board], [item],
                       "a stale payload must not un-file a newer local filing")
    }

    /// The same defect pointing the other way, and the reason a one line fix
    /// is not enough. Two Macs each file a different item onto the SAME board.
    /// Both must end up with both.
    func testTwoMacsFilingOntoTheSameBoardBothSurvive() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let client = R2Client(credentials: creds)
        try await cleanBucket(client)

        let (dbA, storeA) = try makeStore(device: "device-A")
        let (dbB, storeB) = try makeStore(device: "device-B")
        defer { dbA.close(); dbB.close() }

        let a = SyncEngine(client: client, store: storeA, deviceID: "device-A",
                           key: testKey(), prefix: ns)
        let b = SyncEngine(client: client, store: storeB, deviceID: "device-B",
                           key: testKey(), prefix: ns)

        let itemA = UUID(), itemB = UUID()
        try storeA.insert(HistoryItem(id: itemA, text: "kubectl get pods",
                                      sourceBundleID: nil, sourceName: nil, createdAt: Date()))
        try storeA.insert(HistoryItem(id: itemB, text: "kubectl get nodes",
                                      sourceBundleID: nil, sourceName: nil, createdAt: Date()))
        let board = try storeA.createPinboard(name: "k8s")
        try await settle(a, b)

        // Each Mac files one, neither knowing about the other.
        try storeA.setMembership(item: itemA, board: board.id, on: true)
        try storeB.setMembership(item: itemB, board: board.id, on: true)
        try await settle(a, b)

        XCTAssertEqual(try storeA.membership()[board.id], [itemA, itemB],
                       "A must end up with both")
        XCTAssertEqual(try storeB.membership()[board.id], [itemA, itemB],
                       "B must end up with both")
    }
}
