import XCTest
import CryptoKit
@testable import ClipdMac
import ClipdCore

/// Two independent stores pointed at one bucket prefix, which is exactly the
/// two MacBooks. Skips when .env.local is absent.
@MainActor
final class SyncEngineTests: XCTestCase {
    private var paths: [String] = []
    private var dirs: [URL] = []

    /// A throwaway namespace per test run.
    ///
    /// These tests used to operate on the real "items/" and "manifests/" paths
    /// and deleted them as cleanup, which wiped a live history out of the
    /// bucket. Nothing was permanently lost because each Mac keeps its own
    /// copy, but a second device then synced against an empty bucket and looked
    /// broken. Never point a destructive test at production.
    private let ns = "clipd-tests/\(UUID().uuidString)/"

    func testTheTestNamespaceIsNeverTheProductionOne() {
        // A guard against this regressing. If someone drops the prefix, this
        // fails before any destructive test below runs.
        XCTAssertTrue(ns.hasPrefix("clipd-tests/"))
        XCTAssertNotEqual(ns, "")
    }

    override func tearDown() async throws {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        try await super.tearDown()
    }

    private func makeStore() throws -> (Database, SQLiteStore) {
        let path = NSTemporaryDirectory() + "clipd-sync-\(UUID().uuidString).sqlite"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-sync-blobs-\(UUID().uuidString)")
        paths.append(path)
        dirs.append(dir)
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        let blobs = BlobStore(directory: dir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        return (db, SQLiteStore(database: db, blobs: blobs, deviceID: "test"))
    }

    func testTextItemTravelsFromOneMacToTheOther() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let key = SyncCrypto.deriveKey(passphrase: "test-pass",
                                       salt: Data(repeating: 7, count: 32))
        let client = R2Client(credentials: creds)
        // Clean the shared area so a previous run cannot leak into this one.
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }

        let (dbA, storeA) = try makeStore()
        let (dbB, storeB) = try makeStore()
        defer { dbA.close(); dbB.close() }

        let item = HistoryItem(text: "synced from A", sourceBundleID: "com.example",
                               sourceName: "Example", createdAt: Date())
        try storeA.insert(item)

        let a = SyncEngine(client: client, store: storeA,
                                 deviceID: "device-A", key: key, prefix: ns)
        let b = SyncEngine(client: client, store: storeB,
                                 deviceID: "device-B", key: key, prefix: ns)

        let up = try await a.runOnce()
        XCTAssertGreaterThanOrEqual(up.uploaded, 1)

        let down = try await b.runOnce()
        XCTAssertGreaterThanOrEqual(down.downloaded, 1)
        XCTAssertEqual(try storeB.loadAll(limit: 100).map(\.text), ["synced from A"])

        for k in try await client.list(prefix: ns + "items/") { try await client.delete(k) }
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }
    }

    func testADeleteOnOneMacDoesNotComeBackFromTheOther() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let key = SyncCrypto.deriveKey(passphrase: "test-pass",
                                       salt: Data(repeating: 7, count: 32))
        let client = R2Client(credentials: creds)
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }
        for k in try await client.list(prefix: ns + "items/") { try await client.delete(k) }

        let (dbA, storeA) = try makeStore()
        let (dbB, storeB) = try makeStore()
        defer { dbA.close(); dbB.close() }

        let item = HistoryItem(text: "will be deleted", sourceBundleID: nil,
                               sourceName: nil, createdAt: Date())
        try storeA.insert(item)
        let a = SyncEngine(client: client, store: storeA,
                                 deviceID: "device-A", key: key, prefix: ns)
        let b = SyncEngine(client: client, store: storeB,
                                 deviceID: "device-B", key: key, prefix: ns)
        _ = try await a.runOnce()
        _ = try await b.runOnce()
        XCTAssertEqual(try storeB.loadAll(limit: 100).count, 1)

        // Delete on A, sync both ways.
        try storeA.softDelete(id: item.id, at: Date())
        _ = try await a.runOnce()
        _ = try await b.runOnce()

        // Resurrecting deleted items is the single most annoying sync bug.
        XCTAssertTrue(try storeB.loadAll(limit: 100).isEmpty)

        // And it must stay deleted after another round trip.
        _ = try await a.runOnce()
        _ = try await b.runOnce()
        XCTAssertTrue(try storeB.loadAll(limit: 100).isEmpty)

        for k in try await client.list(prefix: ns + "items/") { try await client.delete(k) }
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }
    }

    func testAnImageSurvivesTheRoundTrip() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let key = SyncCrypto.deriveKey(passphrase: "test-pass",
                                       salt: Data(repeating: 7, count: 32))
        let client = R2Client(credentials: creds)
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }
        for k in try await client.list(prefix: ns + "items/") { try await client.delete(k) }

        let (dbA, storeA) = try makeStore()
        let (dbB, storeB) = try makeStore()
        defer { dbA.close(); dbB.close() }

        let pixels = Data((0..<20_000).map { UInt8($0 % 251) })
        try storeA.insert(HistoryItem(imageData: pixels, pixelWidth: 100, pixelHeight: 50,
                                      sourceBundleID: nil, sourceName: nil, createdAt: Date()))

        _ = try await SyncEngine(client: client, store: storeA,
                                 deviceID: "device-A", key: key, prefix: ns).runOnce()
        _ = try await SyncEngine(client: client, store: storeB,
                                 deviceID: "device-B", key: key, prefix: ns).runOnce()

        let arrived = try storeB.loadAll(limit: 10)
        XCTAssertEqual(arrived.count, 1)
        XCTAssertEqual(arrived[0].kind, .image)
        // Byte identical, not merely "an image arrived".
        XCTAssertEqual(arrived[0].imageData, pixels)

        for k in try await client.list(prefix: ns + "items/") { try await client.delete(k) }
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }
    }

    func testAWrongPassphraseCannotReadTheOtherMacsData() async throws {
        guard let creds = R2ClientTests.loadCredentialsForTests() else {
            throw XCTSkip("no .env.local")
        }
        let client = R2Client(credentials: creds)
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }
        for k in try await client.list(prefix: ns + "items/") { try await client.delete(k) }

        let right = SyncCrypto.deriveKey(passphrase: "right", salt: Data(repeating: 7, count: 32))
        let wrong = SyncCrypto.deriveKey(passphrase: "wrong", salt: Data(repeating: 7, count: 32))

        let (dbA, storeA) = try makeStore()
        let (dbB, storeB) = try makeStore()
        defer { dbA.close(); dbB.close() }

        try storeA.insert(HistoryItem(text: "secret", sourceBundleID: nil,
                                      sourceName: nil, createdAt: Date()))
        _ = try await SyncEngine(client: client, store: storeA,
                                 deviceID: "device-A", key: right, prefix: ns).runOnce()
        // The pass must not crash, and must not import anything.
        _ = try? await SyncEngine(client: client, store: storeB,
                                 deviceID: "device-B", key: wrong, prefix: ns).runOnce()
        XCTAssertTrue(try storeB.loadAll(limit: 100).isEmpty)

        for k in try await client.list(prefix: ns + "items/") { try await client.delete(k) }
        for k in try await client.list(prefix: ns + "manifests/") { try await client.delete(k) }
    }
}
