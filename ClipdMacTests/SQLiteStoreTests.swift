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

    // MARK: - Sync payload format

    /// The metadata the old builds put in a sync payload. Everything the items
    /// table needs, nothing invented.
    private func syncJSON(id: UUID, kind: String, text: String?) -> [String: Any] {
        var json: [String: Any] = [
            "id": id.uuidString,
            "kind": kind,
            "created_at": 1_700_000_000_000,
            "updated_at": 1_700_000_000_000,
            "device_id": "the-other-mac",
            "content_hash": "hash-\(id.uuidString)",
            "preview": text ?? "Image",
        ]
        if let text {
            json["text_content"] = text
            json["char_count"] = text.count
        }
        return json
    }

    /// A v0 payload: plain JSON, image base64 encoded inside it.
    private func v0Payload(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }

    /// A v1 payload: 4 byte big endian JSON length, the JSON, then raw image bytes.
    private func v1Payload(_ json: [String: Any], image: Data? = nil) throws -> Data {
        let meta = try JSONSerialization.data(withJSONObject: json)
        var out = Data()
        var length = UInt32(meta.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(meta)
        if let image { out.append(image) }
        return out
    }

    private func assertMalformed(_ error: Error, _ note: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        switch error as? PayloadFormatError {
        case .malformed: break
        default: XCTFail("expected a malformed payload error for \(note), got \(error)",
                         file: file, line: line)
        }
    }

    func testAPayloadStartsWithTheVersionHeader() throws {
        let item = text("header check")
        try store.insert(item)
        let payload = try XCTUnwrap(store.payload(for: item.id))

        XCTAssertEqual(payload.prefix(4), SQLiteStore.payloadMagic)
        XCTAssertEqual(payload[4], 2)
        let length = payload[5 ..< 9].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // A text item has no image bytes, so the JSON runs to the end.
        XCTAssertEqual(Int(length), payload.count - 9)
    }

    func testATextItemRoundTripsThroughAPayload() throws {
        let item = text("arn:aws:s3:::example-bucket")
        try store.insert(item)
        let payload = try XCTUnwrap(store.payload(for: item.id))

        try store.eraseAll()
        try store.apply(payload: payload)

        let loaded = try store.loadAll(limit: 100)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, item.id)
        XCTAssertEqual(loaded[0].text, item.text)
        XCTAssertEqual(loaded[0].sourceBundleID, "com.example.app")
    }

    func testAnImageItemRoundTripsThroughAPayload() throws {
        let data = Data((0 ..< 4096).map { UInt8($0 % 251) })
        let item = HistoryItem(imageData: data, pixelWidth: 640, pixelHeight: 480,
                               sourceBundleID: nil, sourceName: nil, createdAt: Date())
        try store.insert(item)
        let payload = try XCTUnwrap(store.payload(for: item.id))
        // The image must travel raw, not base64, so the payload is only a little
        // bigger than the picture itself.
        XCTAssertLessThan(payload.count, data.count + 1024)

        try store.eraseAll()
        try store.apply(payload: payload)

        let loaded = try store.loadAll(limit: 100)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].kind, .image)
        XCTAssertEqual(loaded[0].imageData, data)
        XCTAssertEqual(loaded[0].pixelWidth, 640)
        XCTAssertEqual(loaded[0].pixelHeight, 480)
    }

    func testAV1PayloadFromAnOlderMacStillApplies() throws {
        let id = UUID()
        let image = Data(repeating: 0x5A, count: 300)
        var json = syncJSON(id: id, kind: "image", text: nil)
        json["px_width"] = 20
        json["px_height"] = 10
        try store.apply(payload: try v1Payload(json, image: image))

        let loaded = try store.loadAll(limit: 100)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id)
        XCTAssertEqual(loaded[0].imageData, image)
    }

    func testAV0Base64PayloadFromAnEvenOlderMacStillApplies() throws {
        let id = UUID()
        let image = Data(repeating: 0x11, count: 256)
        var json = syncJSON(id: id, kind: "image", text: nil)
        json["px_width"] = 32
        json["px_height"] = 32
        json["blob_data"] = image.base64EncodedString()
        try store.apply(payload: try v0Payload(json))

        let loaded = try store.loadAll(limit: 100)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id)
        XCTAssertEqual(loaded[0].imageData, image)
        XCTAssertEqual(loaded[0].pixelWidth, 32)
    }

    func testAV0TextPayloadStillApplies() throws {
        let id = UUID()
        try store.apply(payload: try v0Payload(syncJSON(id: id, kind: "text", text: "old build")))
        XCTAssertEqual(try store.loadAll(limit: 100).map(\.text), ["old build"])
    }

    func testANewerVersionThrowsAndLeavesTheStoreUntouched() throws {
        let item = text("already here")
        try store.insert(item)

        var payload = SQLiteStore.payloadMagic
        payload.append(99)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x02])
        payload.append(Data("{}".utf8))

        XCTAssertThrowsError(try store.apply(payload: payload)) { error in
            // The caller needs to tell "update this Mac" apart from "corrupt
            // bytes", so this must not collapse into a generic failure.
            XCTAssertEqual(error as? PayloadFormatError, .newerVersion(99))
        }
        // Nothing was written, and nothing already in the store was disturbed.
        XCTAssertEqual(try store.loadAll(limit: 100).map(\.text), ["already here"])
        let files = try FileManager.default.contentsOfDirectory(atPath: blobDir.path)
        XCTAssertTrue(files.isEmpty, "a rejected payload wrote a blob")
    }

    func testAnEmptyPayloadThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try store.apply(payload: Data())) { error in
            self.assertMalformed(error, "an empty payload")
        }
    }

    func testATruncatedPayloadThrowsRatherThanCrashing() throws {
        let item = text("will be cut short")
        try store.insert(item)
        let payload = try XCTUnwrap(store.payload(for: item.id))

        // Cut inside the JSON, so the declared length runs past the end.
        XCTAssertThrowsError(try store.apply(payload: payload.dropLast(20))) { error in
            self.assertMalformed(error, "a payload cut inside its metadata")
        }
        // Cut inside the length field itself.
        XCTAssertThrowsError(try store.apply(payload: payload.prefix(7))) { error in
            self.assertMalformed(error, "a payload cut inside its length field")
        }
        // Too short to be framed at all, and not JSON either.
        XCTAssertThrowsError(try store.apply(payload: Data([0x43, 0x4C]))) { error in
            self.assertMalformed(error, "a two byte payload")
        }
        // Right length, but no format matches: not `{`, no magic.
        XCTAssertThrowsError(try store.apply(payload: Data(repeating: 0xEE, count: 32))) { error in
            self.assertMalformed(error, "random bytes")
        }
    }

    func testAPayloadThatIsASliceOfALargerBufferStillApplies() throws {
        let item = text("sliced, not copied")
        try store.insert(item)
        let payload = try XCTUnwrap(store.payload(for: item.id))
        try store.eraseAll()

        // A Data slice keeps the indices of its parent, so this fails if the
        // parser assumes byte 0 is a valid index.
        var padded = Data([0xAA, 0xBB, 0xCC])
        padded.append(payload)
        let slice = padded.dropFirst(3)
        XCTAssertNotEqual(slice.startIndex, 0)

        try store.apply(payload: slice)
        XCTAssertEqual(try store.loadAll(limit: 100).map(\.text), ["sliced, not copied"])
    }
}
