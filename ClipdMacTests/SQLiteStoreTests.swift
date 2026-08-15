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

    // MARK: - Titles

    private func title(of id: UUID) throws -> String? {
        try store.loadAll(limit: 100).first { $0.id == id }?.title
    }

    func testAnItemStartsWithNoTitle() throws {
        let item = text("unnamed")
        try store.insert(item)
        XCTAssertNil(try title(of: item.id))
    }

    func testSettingATitleStoresIt() throws {
        let item = text("kubectl get pods -A")
        try store.insert(item)
        try store.setTitle("prod cluster check", for: item.id)
        XCTAssertEqual(try title(of: item.id), "prod cluster check")
    }

    func testATitleCanBeChanged() throws {
        let item = text("kubectl get pods -A")
        try store.insert(item)
        try store.setTitle("first name", for: item.id)
        try store.setTitle("second name", for: item.id)
        XCTAssertEqual(try title(of: item.id), "second name")
    }

    func testATitleCanBeCleared() throws {
        let item = text("kubectl get pods -A")
        try store.insert(item)
        try store.setTitle("temporary", for: item.id)
        try store.setTitle(nil, for: item.id)
        XCTAssertNil(try title(of: item.id))
    }

    func testABlankTitleIsNoTitleAtAll() throws {
        let item = text("kubectl get pods -A")
        try store.insert(item)
        // A rename dialog left empty, or filled with spaces, means "no name".
        // Storing "   " would make every later check ask two questions instead
        // of one, and would put an empty term in the search index.
        for blank in ["", "   ", "\n", "\t \n "] {
            try store.setTitle(blank, for: item.id)
            XCTAssertNil(try title(of: item.id), "a blank title was stored as a name")
            let rows = try db.query("SELECT title FROM items WHERE id = ?",
                                    [.text(item.id.uuidString)])
            XCTAssertEqual(rows[0]["title"], .null, "a blank title reached the column")
        }
    }

    func testATitleIsTrimmedAndBounded() throws {
        let item = text("kubectl get pods -A")
        try store.insert(item)
        try store.setTitle("  padded  ", for: item.id)
        XCTAssertEqual(try title(of: item.id), "padded")
        // The card header shows one line. A pasted paragraph in the title field
        // must not be stored forever.
        try store.setTitle(String(repeating: "x", count: 500), for: item.id)
        XCTAssertEqual(try title(of: item.id)?.count, 200)
    }

    func testATitleGivenAtInsertTimeIsStored() throws {
        let item = HistoryItem(text: "some payload", sourceBundleID: nil, sourceName: nil,
                               createdAt: Date(), title: "named on the way in")
        try store.insert(item)
        XCTAssertEqual(try title(of: item.id), "named on the way in")
    }

    func testATitleSurvivesReopeningTheDatabase() throws {
        let item = text("persisted with a name")
        try store.insert(item)
        try store.setTitle("the name", for: item.id)
        db.close()

        let reopened = try Database(path: dbPath, key: "test-key")
        let blobs = BlobStore(directory: blobDir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        let store2 = SQLiteStore(database: reopened, blobs: blobs, deviceID: "test-device")
        XCTAssertEqual(try store2.loadAll(limit: 100).first?.title, "the name")
        reopened.close()
    }

    func testAnImageCanBeNamed() throws {
        let item = HistoryItem(imageData: Data(repeating: 0x9, count: 512),
                               pixelWidth: 100, pixelHeight: 50,
                               sourceBundleID: nil, sourceName: nil, createdAt: Date())
        try store.insert(item)
        try store.setTitle("the architecture sketch", for: item.id)
        // An image has no text at all, so a name is the only way to find one on
        // purpose rather than by scrolling.
        XCTAssertEqual(try title(of: item.id), "the architecture sketch")
        XCTAssertEqual(try store.search("sketch", limit: 100).map(\.id), [item.id])
    }

    // MARK: - Titles and sync timing

    func testSettingATitleBumpsUpdatedAtToNow() throws {
        let old = Date(timeIntervalSince1970: 1000)
        let item = HistoryItem(text: "copied long ago", sourceBundleID: nil,
                               sourceName: nil, createdAt: old)
        try store.insert(item)

        let before = Int64(Date().timeIntervalSince1970 * 1000)
        try store.setTitle("named just now", for: item.id)
        let after = Int64(Date().timeIntervalSince1970 * 1000)

        let rows = try db.query("SELECT created_at, updated_at FROM items WHERE id = ?",
                                [.text(item.id.uuidString)])
        guard case .int(let updated)? = rows[0]["updated_at"] else {
            return XCTFail("updated_at is missing")
        }
        // This project already shipped this bug once, in dedup. Sync resolves a
        // conflict by last writer wins on updated_at, so a change stamped with
        // anything older than now can lose to a row the other Mac has been
        // holding untouched, and the name never travels.
        XCTAssertGreaterThanOrEqual(updated, before)
        XCTAssertLessThanOrEqual(updated, after)
        // Naming an item is not copying it, so it must not jump to the top.
        XCTAssertEqual(rows[0]["created_at"], .int(Int64(old.timeIntervalSince1970 * 1000)))
    }

    func testANamedItemKeepsItsPlaceInTheTimeline() throws {
        let older = HistoryItem(text: "older", sourceBundleID: nil, sourceName: nil,
                                createdAt: Date(timeIntervalSince1970: 1000))
        let newer = HistoryItem(text: "newer", sourceBundleID: nil, sourceName: nil,
                                createdAt: Date(timeIntervalSince1970: 2000))
        try store.insert(older)
        try store.insert(newer)
        try store.setTitle("still older", for: older.id)
        XCTAssertEqual(try store.loadAll(limit: 100).map(\.text), ["newer", "older"])
    }

    // MARK: - Titles and search

    func testSearchFindsAnItemByAWordOnlyInItsTitle() throws {
        let item = text("arn:aws:ecs:ap-southeast-3:111:cluster/x")
        try store.insert(item)
        try store.setTitle("staging cluster", for: item.id)
        // The whole point of the feature. "staging" appears nowhere in the
        // content, so before titles this item could only be found by pieces of
        // an ARN the user would have to remember.
        let found = try store.search("staging", limit: 100)
        XCTAssertEqual(found.map(\.id), [item.id])
        XCTAssertEqual(found.first?.title, "staging cluster")
    }

    func testSearchStillFindsANamedItemByItsContent() throws {
        let item = text("docker compose up")
        try store.insert(item)
        try store.setTitle("local stack", for: item.id)
        // Naming an item must ADD a way to find it, never replace the one that
        // was already there.
        XCTAssertEqual(try store.search("compose", limit: 100).map(\.id), [item.id])
        XCTAssertEqual(try store.search("stack", limit: 100).map(\.id), [item.id])
        // Both tokens still AND together, one from each side.
        XCTAssertEqual(try store.search("compose stack", limit: 100).map(\.id), [item.id])
    }

    func testSearchMatchesATitlePrefix() throws {
        let item = text("some opaque payload")
        try store.insert(item)
        try store.setTitle("deployment notes", for: item.id)
        // Typing three letters has to work on a title exactly as it does on
        // content, or search feels broken until the last character.
        XCTAssertEqual(try store.search("dep", limit: 100).map(\.id), [item.id])
    }

    func testRenamingReplacesTheOldNameInSearch() throws {
        let item = text("some opaque payload")
        try store.insert(item)
        try store.setTitle("alpha", for: item.id)
        XCTAssertEqual(try store.search("alpha", limit: 100).count, 1)

        try store.setTitle("bravo", for: item.id)
        // The index holds its own copy of the title, so a rename that did not
        // refresh it would leave the item findable by a name the user deleted.
        XCTAssertEqual(try store.search("bravo", limit: 100).map(\.id), [item.id])
        XCTAssertTrue(try store.search("alpha", limit: 100).isEmpty,
                      "the old name still matches, so the index went stale")
        // Renaming twice hits the same rowid twice, which is what makes the
        // delete before the reindex necessary.
        XCTAssertEqual(try store.loadAll(limit: 100).count, 1)
    }

    func testClearingATitleRemovesItFromSearch() throws {
        let item = text("some opaque payload")
        try store.insert(item)
        try store.setTitle("temporary name", for: item.id)
        try store.setTitle(nil, for: item.id)
        XCTAssertTrue(try store.search("temporary", limit: 100).isEmpty)
        // The content is still indexed, so the item itself is not lost.
        XCTAssertEqual(try store.search("opaque", limit: 100).map(\.id), [item.id])
    }

    func testSearchNeverReturnsATombstonedItemByItsTitle() throws {
        let item = text("secret token abcdef")
        try store.insert(item)
        try store.setTitle("the aws root key", for: item.id)
        try store.softDelete(id: item.id, at: Date())
        // A deleted item reappearing in search would be the worst kind of bug
        // this app could have, and a title is a second way for it to happen.
        XCTAssertTrue(try store.search("root", limit: 100).isEmpty)
        XCTAssertTrue(try store.search("secret", limit: 100).isEmpty)
    }

    func testATitleWithFTS5SyntaxInItIsTreatedAsPlainText() throws {
        let item = text("some opaque payload")
        try store.insert(item)
        try store.setTitle("a AND b OR \"c\"", for: item.id)
        // A title is user typed text and reaches the index the same way content
        // does, so the same quoting rules have to hold on the query side.
        XCTAssertNoThrow(try store.search("AND", limit: 100))
        XCTAssertEqual(try store.search("\"c\"", limit: 100).map(\.id), [item.id])
    }

    // MARK: - Titles and sync payloads

    func testATitleSurvivesAPayloadRoundTrip() throws {
        let item = text("arn:aws:s3:::example-bucket")
        try store.insert(item)
        try store.setTitle("the bucket arn", for: item.id)

        let payload = try XCTUnwrap(store.payload(for: item.id))
        // `payload(for:)` selects an explicit column list, not `*`, so a new
        // column does not travel on its own. This is the check that the list
        // was actually updated.
        // v1 framing: a 4 byte length, then the JSON, and a text item carries no
        // image bytes after it. Copied out of the slice, because a Data slice
        // keeps its parent's indices.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(payload.dropFirst(4))) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "the bucket arn")

        try store.eraseAll()
        try store.apply(payload: payload)

        let loaded = try store.loadAll(limit: 100)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "the bucket arn")
        // And the name is searchable on the far Mac, not just stored there.
        XCTAssertEqual(try store.search("bucket arn", limit: 100).map(\.id), [item.id])
    }

    func testAPayloadWithNoTitleKeyAppliesCleanly() throws {
        let id = UUID()
        // Exactly what a Clipd from before titles writes: the key is not there
        // at all. It must apply as a normal item with no name, not throw and not
        // store an empty string.
        try store.apply(payload: try v1Payload(syncJSON(id: id, kind: "text", text: "from an old mac")))

        let loaded = try store.loadAll(limit: 100)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id)
        XCTAssertNil(loaded[0].title)
        XCTAssertEqual(try store.search("old", limit: 100).map(\.id), [id])
    }

    func testAPayloadCarryingATitleFromAnotherMacApplies() throws {
        let id = UUID()
        var json = syncJSON(id: id, kind: "text", text: "kubectl get pods -A")
        json["title"] = "prod cluster check"
        try store.apply(payload: try v1Payload(json))

        XCTAssertEqual(try store.loadAll(limit: 100).first?.title, "prod cluster check")
        // The far Mac's name has to be indexed here too, or the item is named
        // on one Mac and findable on the other only by its content.
        XCTAssertEqual(try store.search("prod", limit: 100).map(\.id), [id])
    }

    func testABlankTitleInAPayloadArrivesAsNoTitle() throws {
        let id = UUID()
        var json = syncJSON(id: id, kind: "text", text: "from another mac")
        json["title"] = "   "
        // "Blank means no name" is an invariant of the whole app, and a payload
        // is the one door into the column that is not this Mac's own code.
        try store.apply(payload: try v1Payload(json))
        XCTAssertNil(try title(of: id))
        let rows = try db.query("SELECT title FROM items WHERE id = ?", [.text(id.uuidString)])
        XCTAssertEqual(rows[0]["title"], .null)
    }

    /// A known gap, written down as a test rather than left as a surprise.
    ///
    /// An older Clipd drops a title key it does not understand, and its own
    /// payloads never carry one. So when the older Mac makes its OWN change to a
    /// named item, a repeat copy for example, its row is genuinely newer, this
    /// Mac downloads it, and the missing key overwrites the name.
    ///
    /// This test is expected to FAIL, and to be rewritten, on the day the writer
    /// starts sending an explicit null for "no name" and this reader starts
    /// keeping the local title when the key is absent entirely. Same shape as
    /// the payload version flag test above: the behaviour is deliberate today
    /// and the test says so out loud.
    /// An older Mac must not be able to delete a name it cannot see.
    ///
    /// This is the case that makes the absent/null distinction worth having.
    /// Re-copying an item on the 0.3.0 Mac stamps a newer updated_at, so its
    /// payload legitimately wins, and its payload has no title key at all. If
    /// absent meant "no name", the name typed on this Mac would be written over
    /// with NULL. No error, and the item itself survives, so nothing looks
    /// broken until you go looking for the name.
    func testAnOlderMacWritingToANamedItemCannotEraseTheName() throws {
        let item = text("kubectl get pods -A")
        try store.insert(item)
        try store.setTitle("prod cluster check", for: item.id)

        // The older Mac's payload for the same row: everything it knows, which
        // does not include a title, stamped with a later updated_at because it
        // touched the row itself.
        var json = syncJSON(id: item.id, kind: "text", text: item.text)
        json["updated_at"] = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        XCTAssertNil(json["title"], "the payload under test must not carry a title key")
        try store.apply(payload: try v1Payload(json))

        XCTAssertEqual(try title(of: item.id), "prod cluster check")
        XCTAssertEqual(try store.search("prod", limit: 100).map(\.id), [item.id])
        XCTAssertEqual(try store.search("kubectl", limit: 100).map(\.id), [item.id])
    }

    /// Removing a name still has to travel, which is why absent and null differ.
    ///
    /// A current Clipd writes the key with an explicit null when an item has no
    /// name. If it were absent instead, the receiver would protect the old name
    /// and a removal would silently come back.
    func testRemovingANameTravelsRatherThanBeingProtected() throws {
        let item = text("terraform destroy")
        try store.insert(item)
        try store.setTitle("do not run this", for: item.id)

        // The peer removed the name and sent its row.
        var json = syncJSON(id: item.id, kind: "text", text: item.text)
        json["title"] = NSNull()
        json["updated_at"] = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        try store.apply(payload: try v1Payload(json))

        XCTAssertNil(try title(of: item.id))
        XCTAssertTrue(try store.search("do not run", limit: 100).isEmpty)
        XCTAssertEqual(try store.search("terraform", limit: 100).map(\.id), [item.id])
    }

    /// The writer half of the pair: a nameless item says so out loud.
    func testAPayloadAlwaysCarriesTheTitleKeyEvenWhenThereIsNoName() throws {
        let item = text("no name here")
        try store.insert(item)
        let payload = try XCTUnwrap(store.payload(for: item.id))

        // v1 framing: 4 byte length, then the JSON.
        let length = Int(payload[0 ..< 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let meta = payload.subdata(in: 4 ..< (4 + length))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: meta) as? [String: Any])

        XCTAssertTrue(json.keys.contains("title"), "absent would be read as an older writer")
        XCTAssertTrue(json["title"] is NSNull)
    }

    // MARK: - Migration 3 on a database that already holds history

    /// Builds a database at the schema it had before titles: migrations 1 and 2
    /// applied, user_version pinned to 2, nothing else.
    private func makeVersion2Database(at path: String) throws -> Database {
        let database = try Database(path: path, key: "test-key")
        for migration in Schema.migrations where migration.version <= 2 {
            for statement in migration.statements {
                try database.execute(statement)
            }
        }
        try database.execute("PRAGMA user_version = 2")
        return database
    }

    func testMigratingAPopulatedDatabaseAddsTheColumnAndKeepsEverythingSearchable() throws {
        let path = NSTemporaryDirectory() + "clipd-migrate-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = try makeVersion2Database(at: path)

        // Two live rows and one tombstone, written the way version 2 wrote them.
        let live = UUID(), alsoLive = UUID(), gone = UUID()
        for (id, content, deleted) in [(live, "terraform apply", false),
                                       (alsoLive, "docker compose up", false),
                                       (gone, "already deleted", true)] {
            try old.run("""
                INSERT INTO items
                  (id, kind, created_at, updated_at, deleted_at, device_id,
                   content_hash, text_content, preview, char_count, pinned)
                VALUES (?,'text',1000,1000,?,'old-mac',?,?,?,?,0)
                """, [.text(id.uuidString), deleted ? .int(1000) : .null,
                      .text("hash-\(id.uuidString)"), .text(content), .text(content),
                      .int(Int64(content.count))])
        }
        try old.execute("""
            INSERT INTO items_fts(rowid, text_content, preview)
            SELECT rowid, text_content, preview FROM items WHERE deleted_at IS NULL
            """)
        XCTAssertEqual(old.userVersion, 2)

        try old.migrate()
        XCTAssertEqual(old.userVersion, Schema.latestVersion)

        // The column is there.
        let itemColumns = try old.query("PRAGMA table_info(items)", []).compactMap { row -> String? in
            if case .text(let name)? = row["name"] { return name } else { return nil }
        }
        XCTAssertTrue(itemColumns.contains("title"), "items has no title column after migrating")

        // And the rebuilt index has all three columns, which ALTER could never
        // have given it.
        let ftsColumns = try old.query("PRAGMA table_info(items_fts)", []).compactMap { row -> String? in
            if case .text(let name)? = row["name"] { return name } else { return nil }
        }
        XCTAssertEqual(ftsColumns, ["text_content", "preview", "title"])

        // The rows the user already had are still findable. An index that came
        // out of the rebuild empty would make months of history silently
        // unreachable, with nothing on screen to say so.
        let blobs = BlobStore(directory: blobDir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        let migrated = SQLiteStore(database: old, blobs: blobs, deviceID: "test-device")
        XCTAssertEqual(try migrated.search("terraform", limit: 100).map(\.id), [live])
        XCTAssertEqual(try migrated.search("compose", limit: 100).map(\.id), [alsoLive])
        XCTAssertEqual(try migrated.loadAll(limit: 100).count, 2)
        // The tombstone stayed out of the rebuilt index and out of the list.
        XCTAssertTrue(try migrated.search("deleted", limit: 100).isEmpty)

        // An existing row has no name, and can be given one straight away.
        XCTAssertNil(try migrated.loadAll(limit: 100).first { $0.id == live }?.title)
        try migrated.setTitle("the deploy command", for: live)
        XCTAssertEqual(try migrated.search("deploy", limit: 100).map(\.id), [live])

        old.close()
    }

    func testMigratingRunsOnlyOnceEvenIfTheAppReopens() throws {
        let path = NSTemporaryDirectory() + "clipd-migrate-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try makeVersion2Database(at: path)
        try database.run("""
            INSERT INTO items
              (id, kind, created_at, updated_at, device_id, content_hash,
               text_content, preview, char_count, pinned)
            VALUES (?,'text',1000,1000,'old-mac','h','kubectl get pods','kubectl get pods',16,0)
            """, [.text(UUID().uuidString)])
        try database.migrate()

        let blobs = BlobStore(directory: blobDir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        let migrated = SQLiteStore(database: database, blobs: blobs, deviceID: "test-device")
        let id = try XCTUnwrap(migrated.loadAll(limit: 10).first?.id)
        try migrated.setTitle("named after migrating", for: id)

        // A second call must be a no-op. If it ran migration 3 again it would
        // drop the index and rebuild it from `items`, which is harmless for
        // content but would be a silent full rebuild on every launch.
        try database.migrate()
        XCTAssertEqual(try migrated.search("named", limit: 100).map(\.id), [id])
        XCTAssertEqual(try migrated.search("kubectl", limit: 100).map(\.id), [id])
        database.close()
    }
}
