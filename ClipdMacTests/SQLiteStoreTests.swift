import XCTest
@testable import ClipdMac
import ClipdCore

final class SQLiteStoreTests: XCTestCase {
    private var dbPath: String!
    private var blobDir: URL!
    private var db: Database!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbPath = NSTemporaryDirectory() + "clipd-store-\(UUID().uuidString).sqlite"
        blobDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-store-blobs-\(UUID().uuidString)")
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

    private func text(_ s: String) -> HistoryItem {
        HistoryItem(text: s, sourceBundleID: "com.example.app",
                    sourceName: "Example", createdAt: Date())
    }

    func testTextRoundTrips() throws {
        let item = text("arn:aws:ecs:ap-southeast-3")
        try store.insert(item)
        let loaded = try store.loadAll(limit: 100)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].text, item.text)
        XCTAssertEqual(loaded[0].id, item.id)
        XCTAssertEqual(loaded[0].sourceBundleID, "com.example.app")
    }

    func testImageRoundTripsThroughTheBlobStore() throws {
        let data = Data(repeating: 0x42, count: 5000)
        let item = HistoryItem(imageData: data, pixelWidth: 800, pixelHeight: 600,
                               sourceBundleID: "com.apple.screencaptureui",
                               sourceName: "Screenshot", createdAt: Date())
        try store.insert(item)
        let loaded = try store.loadAll(limit: 100)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].kind, .image)
        XCTAssertEqual(loaded[0].imageData, data)
        XCTAssertEqual(loaded[0].pixelWidth, 800)
    }

    func testNewestFirst() throws {
        let old = HistoryItem(text: "old", sourceBundleID: nil, sourceName: nil,
                              createdAt: Date(timeIntervalSince1970: 1000))
        let new = HistoryItem(text: "new", sourceBundleID: nil, sourceName: nil,
                              createdAt: Date(timeIntervalSince1970: 2000))
        try store.insert(old)
        try store.insert(new)
        XCTAssertEqual(try store.loadAll(limit: 100).map(\.text), ["new", "old"])
    }

    func testSoftDeleteHidesTheRowButKeepsATombstone() throws {
        let item = text("delete me")
        try store.insert(item)
        try store.softDelete(id: item.id, at: Date())
        XCTAssertTrue(try store.loadAll(limit: 100).isEmpty)
        // The row must still be there, or a sync would resurrect it.
        let rows = try db.query("SELECT deleted_at FROM items WHERE id = ?",
                                [.text(item.id.uuidString)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotEqual(rows[0]["deleted_at"], .null)
    }

    func testHardDeleteLeavesNothingAtAll() throws {
        let data = Data(repeating: 0x7, count: 200)
        let item = HistoryItem(imageData: data, pixelWidth: 10, pixelHeight: 10,
                               sourceBundleID: nil, sourceName: nil, createdAt: Date())
        try store.insert(item)
        try store.hardDelete(id: item.id)
        // A secret caught late by the auto-clear rule must not survive as a
        // soft deleted row, and its blob must be gone from disk.
        let rows = try db.query("SELECT id FROM items WHERE id = ?",
                                [.text(item.id.uuidString)])
        XCTAssertTrue(rows.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: blobDir.path)
        XCTAssertTrue(files.isEmpty, "blob survived a hard delete")
    }

    func testTouchDoesNotCreateASecondRow() throws {
        let item = text("same")
        try store.insert(item)
        try store.touch(id: item.id, at: Date(timeIntervalSince1970: 9999))
        let rows = try db.query("SELECT count(*) AS n FROM items", [])
        XCTAssertEqual(rows[0]["n"], .int(1))
    }

    func testSurvivesReopeningTheDatabase() throws {
        try store.insert(text("persisted"))
        db.close()

        let reopened = try Database(path: dbPath, key: "test-key")
        let blobs = BlobStore(directory: blobDir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        let store2 = SQLiteStore(database: reopened, blobs: blobs, deviceID: "test-device")
        XCTAssertEqual(try store2.loadAll(limit: 100).map(\.text), ["persisted"])
        reopened.close()
    }

    func testAnImageRowWithAMissingBlobIsSkippedRatherThanShown() throws {
        let item = HistoryItem(imageData: Data([1, 2, 3]), pixelWidth: 4, pixelHeight: 4,
                               sourceBundleID: nil, sourceName: nil, createdAt: Date())
        try store.insert(item)
        // Simulate a blob deleted out from under the row.
        for file in try FileManager.default.contentsOfDirectory(atPath: blobDir.path) {
            try FileManager.default.removeItem(at: blobDir.appendingPathComponent(file))
        }
        // A card that cannot be pasted is worse than no card.
        XCTAssertTrue(try store.loadAll(limit: 100).isEmpty)
    }
}
