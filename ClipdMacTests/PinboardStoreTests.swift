import XCTest
@testable import ClipdMac
import ClipdCore

final class PinboardStoreTests: XCTestCase {
    private var dbPath: String!
    private var blobDir: URL!
    private var db: Database!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbPath = NSTemporaryDirectory() + "clipd-board-\(UUID().uuidString).sqlite"
        blobDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-board-blobs-\(UUID().uuidString)")
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

    func testCreateAndList() throws {
        let work = try store.createPinboard(name: "Work")
        let home = try store.createPinboard(name: "Home")
        let all = try store.allPinboards()
        XCTAssertEqual(all.map(\.name), ["Work", "Home"])
        // Distinct colours, so two boards never look the same.
        XCTAssertNotEqual(work.colorName, home.colorName)
        XCTAssertLessThan(work.sortOrder, home.sortOrder)
    }

    func testMembershipRoundTrips() throws {
        let board = try store.createPinboard(name: "Work")
        let item = HistoryItem(text: "on the board", sourceBundleID: nil,
                               sourceName: nil, createdAt: Date())
        try store.insert(item)
        try store.setMembership(item: item.id, board: board.id, on: true)
        XCTAssertEqual(try store.membership()[board.id], [item.id])

        try store.setMembership(item: item.id, board: board.id, on: false)
        XCTAssertTrue((try store.membership()[board.id] ?? []).isEmpty)
    }

    func testDELETING_A_BOARD_NEVER_DELETES_ITS_ITEMS() throws {
        let board = try store.createPinboard(name: "Doomed")
        let item = HistoryItem(text: "must survive", sourceBundleID: nil,
                               sourceName: nil, createdAt: Date())
        try store.insert(item)
        try store.setMembership(item: item.id, board: board.id, on: true)

        try store.deletePinboard(id: board.id)

        // A board is a label, not a container. Losing history because you tidied
        // up a board would be unforgivable.
        XCTAssertEqual(try store.loadAll(limit: 100).map(\.text), ["must survive"])
        XCTAssertTrue(try store.allPinboards().isEmpty)
    }

    func testRename() throws {
        let board = try store.createPinboard(name: "Old")
        try store.renamePinboard(id: board.id, to: "New")
        XCTAssertEqual(try store.allPinboards().map(\.name), ["New"])
    }

    func testDeletedBoardsDoNotReappear() throws {
        let board = try store.createPinboard(name: "Gone")
        try store.deletePinboard(id: board.id)
        // A tombstone, not a row removal, so a sync cannot resurrect it.
        XCTAssertTrue(try store.allPinboards().isEmpty)
        let rows = try db.query("SELECT deleted_at FROM pinboards WHERE id = ?",
                                [.text(board.id.uuidString)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotEqual(rows[0]["deleted_at"], .null)
    }

    func testPinnedItemIDsAreEveryItemOnAnyBoard() throws {
        let a = try store.createPinboard(name: "A")
        let b = try store.createPinboard(name: "B")
        let one = HistoryItem(text: "one", sourceBundleID: nil, sourceName: nil, createdAt: Date())
        let two = HistoryItem(text: "two", sourceBundleID: nil, sourceName: nil, createdAt: Date())
        let loose = HistoryItem(text: "loose", sourceBundleID: nil, sourceName: nil, createdAt: Date())
        for i in [one, two, loose] { try store.insert(i) }
        try store.setMembership(item: one.id, board: a.id, on: true)
        try store.setMembership(item: two.id, board: b.id, on: true)

        // Retention must not expire anything filed on a board.
        XCTAssertEqual(try store.pinnedItemIDs(), Set([one.id, two.id]))
    }

    func testSettingTheSameMembershipTwiceIsHarmless() throws {
        let board = try store.createPinboard(name: "Work")
        let item = HistoryItem(text: "x", sourceBundleID: nil, sourceName: nil, createdAt: Date())
        try store.insert(item)
        try store.setMembership(item: item.id, board: board.id, on: true)
        XCTAssertNoThrow(try store.setMembership(item: item.id, board: board.id, on: true))
        XCTAssertEqual(try store.membership()[board.id]?.count, 1)
    }
}
