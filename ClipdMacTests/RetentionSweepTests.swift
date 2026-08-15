import XCTest
@testable import ClipdMac
import ClipdCore

final class RetentionSweepTests: XCTestCase {
    private var dbPath: String!
    private var blobDir: URL!
    private var db: Database!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbPath = NSTemporaryDirectory() + "clipd-sweep-\(UUID().uuidString).sqlite"
        blobDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-sweep-blobs-\(UUID().uuidString)")
        db = try Database(path: dbPath, key: "test-key")
        try db.migrate()
        let blobs = BlobStore(directory: blobDir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        store = SQLiteStore(database: db, blobs: blobs, deviceID: "test-device")
    }

    override func tearDown() {
        db?.close()
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(at: blobDir)
        super.tearDown()
    }

    func testExpireHidesTheItemButLeavesATombstone() throws {
        let item = HistoryItem(text: "old", sourceBundleID: nil, sourceName: nil,
                               createdAt: Date(timeIntervalSince1970: 1000))
        try store.insert(item)
        try store.expire(ids: [item.id], at: Date())

        XCTAssertTrue(try store.loadAll(limit: 100).isEmpty)
        // The tombstone must survive, or a v1.1 sync would resurrect it.
        let rows = try db.query("SELECT deleted_at FROM items WHERE id = ?",
                                [.text(item.id.uuidString)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotEqual(rows[0]["deleted_at"], .null)
    }

    func testExpireDeletesTheBlobImmediately() throws {
        let item = HistoryItem(imageData: Data(repeating: 9, count: 5000),
                               pixelWidth: 10, pixelHeight: 10,
                               sourceBundleID: nil, sourceName: nil, createdAt: Date())
        try store.insert(item)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blobDir.path).count, 1)
        try store.expire(ids: [item.id], at: Date())
        // A tombstone that leaves a 2.8 MB screenshot behind is not a delete.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blobDir.path).count, 0)
    }

    func testExpireOnAnEmptyListDoesNothing() throws {
        try store.insert(HistoryItem(text: "keep", sourceBundleID: nil,
                                     sourceName: nil, createdAt: Date()))
        try store.expire(ids: [], at: Date())
        XCTAssertEqual(try store.loadAll(limit: 100).count, 1)
    }

    func testEraseAllRemovesRowsAndBlobsOutright() throws {
        try store.insert(HistoryItem(text: "one", sourceBundleID: nil,
                                     sourceName: nil, createdAt: Date()))
        try store.insert(HistoryItem(imageData: Data(repeating: 1, count: 100),
                                     pixelWidth: 2, pixelHeight: 2,
                                     sourceBundleID: nil, sourceName: nil, createdAt: Date()))
        try store.eraseAll()

        // Hard delete, not tombstones. The user asked for it to be gone, and
        // tombstones would ship the shape of their whole history to R2.
        let rows = try db.query("SELECT count(*) AS n FROM items", [])
        XCTAssertEqual(rows[0]["n"], .int(0))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: blobDir.path).isEmpty)
    }

    func testTheWholeSweepPathEndToEnd() throws {
        let now = Date()
        let old = HistoryItem(text: "old", sourceBundleID: nil, sourceName: nil,
                              createdAt: now.addingTimeInterval(-10 * 24 * 3600))
        let fresh = HistoryItem(text: "fresh", sourceBundleID: nil, sourceName: nil,
                                createdAt: now)
        try store.insert(old)
        try store.insert(fresh)

        let loaded = try store.loadAll(limit: 100)
        let doomed = itemsToExpire(loaded, policy: .week, pinned: [], now: now)
        try store.expire(ids: doomed, at: now)

        XCTAssertEqual(try store.loadAll(limit: 100).map(\.text), ["fresh"])
    }
}
