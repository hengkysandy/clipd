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

    // MARK: - Search

    func testSearchFindsASingleToken() throws {
        try store.insert(text("docker compose up"))
        try store.insert(text("kubectl get pods"))
        let found = try store.search("compose", limit: 100)
        XCTAssertEqual(found.map(\.text), ["docker compose up"])
        // Search must return a whole item, not just a matching string, so the
        // panel can paste it and show where it came from.
        XCTAssertEqual(found[0].sourceBundleID, "com.example.app")
    }

    func testSearchRequiresEveryToken() throws {
        try store.insert(text("docker compose up"))
        try store.insert(text("docker build ."))
        // Both tokens must be present, in any order, the same rule the panel
        // used when it filtered the in-memory list.
        XCTAssertEqual(try store.search("docker compose", limit: 100).map(\.text),
                       ["docker compose up"])
        XCTAssertEqual(try store.search("compose docker", limit: 100).map(\.text),
                       ["docker compose up"])
        XCTAssertTrue(try store.search("docker kubectl", limit: 100).isEmpty)
    }

    func testSearchMatchesAPrefix() throws {
        try store.insert(text("docker compose up"))
        // Typing three letters has to find the word. Without the prefix
        // operator FTS5 would only match a whole term and search would feel
        // broken until the last character.
        XCTAssertEqual(try store.search("doc", limit: 100).map(\.text), ["docker compose up"])
        XCTAssertEqual(try store.search("doc comp", limit: 100).map(\.text), ["docker compose up"])
    }

    func testSearchIsCaseInsensitive() throws {
        try store.insert(text("Docker Compose Up"))
        XCTAssertEqual(try store.search("docker", limit: 100).count, 1)
        XCTAssertEqual(try store.search("DOCKER", limit: 100).count, 1)
        XCTAssertEqual(try store.search("dOcKeR", limit: 100).count, 1)
    }

    func testSearchNeverReturnsATombstonedItem() throws {
        let item = text("secret token abcdef")
        try store.insert(item)
        XCTAssertEqual(try store.search("secret", limit: 100).count, 1)
        try store.softDelete(id: item.id, at: Date())
        // A deleted item reappearing in search results would be the worst kind
        // of bug this app could have.
        XCTAssertTrue(try store.search("secret", limit: 100).isEmpty)
    }

    func testSearchIsNewestFirst() throws {
        for (offset, label) in [(1000.0, "shared one"), (2000.0, "shared two"), (3000.0, "shared three")] {
            try store.insert(HistoryItem(text: label, sourceBundleID: nil, sourceName: nil,
                                         createdAt: Date(timeIntervalSince1970: offset)))
        }
        // A clipboard history is a timeline. Relevance ranking would put the
        // thing you copied 30 seconds ago below an older, better scoring match.
        XCTAssertEqual(try store.search("shared", limit: 100).map(\.text),
                       ["shared three", "shared two", "shared one"])
    }

    func testSearchRespectsTheLimit() throws {
        for i in 0 ..< 5 {
            try store.insert(HistoryItem(text: "shared \(i)", sourceBundleID: nil, sourceName: nil,
                                         createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        let found = try store.search("shared", limit: 2)
        XCTAssertEqual(found.map(\.text), ["shared 4", "shared 3"])
    }

    func testSearchReturnsAnImageItemIntact() throws {
        let data = Data(repeating: 0x33, count: 4096)
        let item = HistoryItem(imageData: data, pixelWidth: 800, pixelHeight: 600,
                               sourceBundleID: "com.apple.screencaptureui",
                               sourceName: "Screenshot", createdAt: Date())
        try store.insert(item)
        // An image has no text at all. Its preview is "Image 800 x 600", which
        // is indexed, so typing "image" or a dimension finds it.
        let found = try store.search("image", limit: 100)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].kind, .image)
        XCTAssertEqual(found[0].imageData, data)
        XCTAssertEqual(found[0].pixelWidth, 800)
        XCTAssertEqual(found[0].sourceName, "Screenshot")
        XCTAssertEqual(try store.search("800", limit: 100).count, 1)
    }

    func testSearchFindsItemsOlderThanTheInMemoryWindow() throws {
        // The whole point of using the index. The panel only holds the newest
        // 500 rows in memory, so before this the 501st item was unfindable.
        for i in 0 ..< 520 {
            try store.insert(HistoryItem(text: i == 0 ? "needle in the haystack" : "filler \(i)",
                                         sourceBundleID: nil, sourceName: nil,
                                         createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        XCTAssertEqual(try store.search("needle", limit: 100).map(\.text),
                       ["needle in the haystack"])
    }

    func testAQueryWithNothingSearchableMatchesNothing() throws {
        try store.insert(text("docker compose up"))
        // Rejected: returning the whole history. The panel already shows
        // everything when the field is empty, and answering ":::" with every
        // item ever copied looks like search quietly gave up.
        for query in ["", "   ", ":::", "-", "*", "()", "😀"] {
            XCTAssertTrue(try store.search(query, limit: 100).isEmpty,
                          "expected no results for a query with no searchable text")
        }
    }

    func testFTS5OperatorsAreTreatedAsPlainText() throws {
        try store.insert(text("apple"))
        // If OR reached FTS5 as an operator, "a" alone would match "apple" and
        // this would return a row. Quoting every token is what stops that.
        XCTAssertTrue(try store.search("a OR b", limit: 100).isEmpty)
        XCTAssertTrue(try store.search("apple NOT apple", limit: 100).isEmpty)
        // A quote in the query is doubled, not dropped, so the word still matches.
        try store.insert(text("he said \"hello\" loudly"))
        XCTAssertEqual(try store.search("\"hello\"", limit: 100).count, 1)
    }

    func testHostileQueriesNeverThrow() throws {
        try store.insert(text("docker compose up"))
        try store.insert(text("arn:aws:ecs:ap-southeast-3"))
        // Every one of these is either FTS5 syntax or a character the query
        // language treats as special. The search field takes pasted text, so
        // all of them will arrive sooner or later. None may throw, and none may
        // take the panel down mid-keystroke.
        let hostile = [
            "\"", "*", "-foo", "a OR b", "(", ")", "((()", "NEAR/2", "NEAR(a b)",
            ":", "^", "^foo", "col:foo", "a AND NOT b", "\"unbalanced", "a*b",
            "AND", "OR", "NOT", "{}", "\\", "%", "😀", "😀 docker", "-", "--",
            String(repeating: "x", count: 5000),
            String(repeating: "a ", count: 2500),
            "arn:aws:ecs:ap-southeast-3",
        ]
        for query in hostile {
            XCTAssertNoThrow(try store.search(query, limit: 100),
                             "a hostile query threw instead of returning results")
        }
        // The store is still usable afterwards.
        XCTAssertEqual(try store.search("docker", limit: 100).count, 1)
    }

    func testSearchReturnsNothingRatherThanThrowingOnADamagedIndex() throws {
        try store.insert(text("docker compose up"))
        // Stand-in for the "database disk image is malformed" this project
        // already hit from an FTS5 misuse. Whatever the index does, a user
        // typing in the search field must not see a thrown error.
        try db.execute("DROP TABLE items_fts")
        var found: [HistoryItem]?
        XCTAssertNoThrow(found = try store.search("docker", limit: 100))
        XCTAssertEqual(found?.count, 0)
        // The history itself is untouched, so the panel still lists everything.
        XCTAssertEqual(try store.loadAll(limit: 100).count, 1)
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

    /// The writer must stay on v1 until both Macs can read v2.
    ///
    /// This is the test that stops a silent one way sync. The 0.3.0 parser reads
    /// the v2 magic as a 4 byte length, gets about 1.07 GB, fails its own bounds
    /// check and returns without a throw or a log. Every item written by a v2
    /// writer would simply never arrive on the older Mac, while sync kept
    /// reporting success. When the flag is finally flipped, this test is
    /// supposed to fail and be updated on purpose.
    func testTheWriterStillEmitsV1SoAnOlderMacCanReadIt() throws {
        XCTAssertFalse(SQLiteStore.writesFramedPayload,
                       "flip this test at the same time as the flag, not before")

        let item = text("header check")
        try store.insert(item)
        let payload = try XCTUnwrap(store.payload(for: item.id))

        XCTAssertNotEqual(payload.prefix(4), SQLiteStore.payloadMagic)
        // v1 is a 4 byte big endian length, then JSON, so byte 4 is `{`.
        XCTAssertEqual(payload[4], 0x7B)
        let length = payload[0 ..< 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // A text item has no image bytes, so the JSON runs to the end.
        XCTAssertEqual(Int(length), payload.count - 4)
    }

    /// The v2 READER has to keep working even though nothing writes v2 yet.
    ///
    /// Without this, the reader would be untested from the day the writer was
    /// turned off until the day it is turned back on, which is exactly when it
    /// needs to be trusted.
    func testAV2PayloadStillAppliesEvenThoughNothingWritesOneYet() throws {
        let item = text("written by a future Clipd")
        try store.insert(item)
        let v1 = try XCTUnwrap(store.payload(for: item.id))

        // Re-frame the v1 payload as v2 by hand: magic, version byte, then the
        // v1 bytes unchanged.
        var v2 = Data()
        v2.append(SQLiteStore.payloadMagic)
        v2.append(SQLiteStore.currentPayloadVersion)
        v2.append(v1)

        try store.eraseAll()
        try store.apply(payload: v2)

        XCTAssertEqual(try store.loadAll(limit: 10).map(\.text),
                       ["written by a future Clipd"])
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
