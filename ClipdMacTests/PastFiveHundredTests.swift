import XCTest
import AppKit
@testable import ClipdMac
import ClipdCore

/// Everything that used to assume the in-memory history WAS the history.
///
/// The panel keeps only the newest 500 items in memory. Several features
/// filtered that list as though it held every row, and every one of them broke
/// silently the day a history passed 500 items. Reported for the board tab:
/// an item ticked under "personal" in the Pin menu, with its card painted the
/// board's colour, while the personal tab said "Nothing pinned to personal
/// yet". The tick and the colour read the store; the tab read memory.
///
/// Each test builds 600 items so the thing under test sits past the cap.
@MainActor
final class PastFiveHundredTests: XCTestCase {
    private var dbPath: String!
    private var blobDir: URL!
    private var db: Database!
    private var store: SQLiteStore!
    /// Oldest first. allItems[0] is the one that falls outside the newest 500.
    private var allItems: [HistoryItem] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbPath = NSTemporaryDirectory() + "clipd-600-\(UUID().uuidString).sqlite"
        blobDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-600-blobs-\(UUID().uuidString)")
        db = try Database(path: dbPath, key: "test-key")
        try db.migrate()
        let blobs = BlobStore(directory: blobDir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32)))
        store = SQLiteStore(database: db, blobs: blobs, deviceID: "test-device")

        let start = Date().addingTimeInterval(-600 * 60)
        allItems = (0..<600).map { i in
            HistoryItem(text: "item number \(i)", sourceBundleID: nil, sourceName: nil,
                        createdAt: start.addingTimeInterval(Double(i) * 60))
        }
        for item in allItems { try store.insert(item) }
    }

    override func tearDown() {
        db?.close()
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(at: blobDir)
        super.tearDown()
    }

    private var oldest: HistoryItem { allItems[0] }

    /// Sanity for the whole file: the oldest item really is outside the window
    /// the panel holds in memory, or none of the other tests mean anything.
    func testTheOldestItemIsOutsideTheInMemoryWindow() throws {
        let window = try store.loadAll(limit: 500).map(\.id)
        XCTAssertEqual(window.count, 500)
        XCTAssertFalse(window.contains(oldest.id))
    }

    // MARK: - The reported bug

    func testABoardReturnsAnItemFiledLongAgo() throws {
        let board = try store.createPinboard(name: "personal")
        try store.setMembership(item: oldest.id, board: board.id, on: true)
        XCTAssertEqual(try store.items(onBoard: board.id).map(\.id), [oldest.id])
    }

    func testABoardDoesNotShowADeletedItem() throws {
        let board = try store.createPinboard(name: "personal")
        try store.setMembership(item: oldest.id, board: board.id, on: true)
        try store.expire(ids: [oldest.id], at: Date())
        XCTAssertEqual(try store.items(onBoard: board.id), [])
    }

    func testABoardDoesNotShowAnItemTakenOffIt() throws {
        let board = try store.createPinboard(name: "personal")
        try store.setMembership(item: oldest.id, board: board.id, on: true)
        try store.setMembership(item: oldest.id, board: board.id, on: false)
        XCTAssertEqual(try store.items(onBoard: board.id), [])
    }

    func testABoardShowsOnlyItsOwnItemsNewestFirst() throws {
        let personal = try store.createPinboard(name: "personal")
        let other = try store.createPinboard(name: "other")
        try store.setMembership(item: allItems[0].id, board: personal.id, on: true)
        try store.setMembership(item: allItems[599].id, board: personal.id, on: true)
        try store.setMembership(item: allItems[300].id, board: other.id, on: true)
        XCTAssertEqual(try store.items(onBoard: personal.id).map(\.id),
                       [allItems[599].id, allItems[0].id])
    }

    /// The end to end version, through the real panel, which is where the bug
    /// actually lived. The in-memory history gets only the newest 500, exactly
    /// as the app loads it. Confirmed to FAIL with the board tab reading the
    /// in-memory list, which is what it did before this fix.
    func testTheBoardTabShowsAnItemFiledLongAgo() throws {
        let board = try store.createPinboard(name: "personal")
        try store.setMembership(item: oldest.id, board: board.id, on: true)

        let history = History()
        history.load(try store.loadAll(limit: 500))
        let controller = PanelController(history: history)
        controller.screenFrame = { NSRect(x: 0, y: 0, width: 1470, height: 956) }
        let store = self.store!
        controller.boardProvider = {
            ((try? store.allPinboards()) ?? [], (try? store.membership()) ?? [:])
        }
        controller.boardItemsProvider = { (try? store.items(onBoard: $0)) ?? [] }

        controller.show()
        defer { controller.panel.orderOut(nil) }
        // Cmd+Right, the real keyboard path from Clipboard to the first board.
        XCTAssertEqual(controller.panel.onBoardStep?(1), true)

        XCTAssertEqual(controller.results.map(\.id), [oldest.id],
                       "the board tab must show what is filed on it, however old")
    }

    // MARK: - Retention, the same mistake in a different place

    func testEveryStoredItemReachesTheRetentionRule() throws {
        let dates = try store.liveItemDates()
        XCTAssertEqual(dates.count, 600, "the sweep must see every row, not the newest 500")
        XCTAssertTrue(dates.contains { $0.id == oldest.id })
    }

    /// The dates must come back exactly, or the rule ages items wrongly.
    func testStoredDatesRoundTripToTheMillisecond() throws {
        let byID = Dictionary(uniqueKeysWithValues: try store.liveItemDates().map { ($0.id, $0.createdAt) })
        let stored = try XCTUnwrap(byID[oldest.id])
        XCTAssertEqual(stored.timeIntervalSince1970, oldest.createdAt.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testRetentionExpiresAnOldItemPastTheWindowButSparesAPinnedOne() throws {
        let board = try store.createPinboard(name: "keep")
        try store.setMembership(item: allItems[1].id, board: board.id, on: true)
        // Ten hours after the newest item, with a one day policy, nothing is
        // due. Thirty days after, the first two are past it; the pinned one
        // must survive.
        let now = allItems[599].createdAt.addingTimeInterval(30 * 86_400)
        let doomed = idsToExpire(try store.liveItemDates(), policy: .day,
                                 pinned: try store.pinnedItemIDs(), now: now)
        XCTAssertTrue(doomed.contains(oldest.id), "an item outside the newest 500 must still expire")
        XCTAssertFalse(doomed.contains(allItems[1].id), "a pinned item never expires")
    }

    func testTheRealCountIsNotTheInMemoryOne() throws {
        XCTAssertEqual(try store.liveItemCount(), 600)
        try store.expire(ids: [oldest.id], at: Date())
        XCTAssertEqual(try store.liveItemCount(), 599)
    }
}
