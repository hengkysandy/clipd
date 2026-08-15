import XCTest
@testable import ClipdMac
import ClipdCore

final class DatabaseTests: XCTestCase {
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "clipd-test-\(UUID().uuidString).sqlite"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testMigratesAFreshDatabaseToTheLatestVersion() throws {
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        XCTAssertEqual(db.userVersion, Schema.latestVersion)
        db.close()
    }

    func testMigrateIsIdempotent() throws {
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        // Running it again must not throw "table already exists".
        XCTAssertNoThrow(try db.migrate())
        XCTAssertEqual(db.userVersion, Schema.latestVersion)
        db.close()
    }

    func testRoundTripsEveryValueType() throws {
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        try db.execute("CREATE TABLE t (a TEXT, b INTEGER, c BLOB, d TEXT)")
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?)",
                   [.text("hello"), .int(42), .blob(Data([1, 2, 3])), .null])
        let rows = try db.query("SELECT a, b, c, d FROM t", [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["a"], .text("hello"))
        XCTAssertEqual(rows[0]["b"], .int(42))
        XCTAssertEqual(rows[0]["c"], .blob(Data([1, 2, 3])))
        XCTAssertEqual(rows[0]["d"], .null)
        db.close()
    }

    func testTheFileOnDiskIsActuallyEncrypted() throws {
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        try db.run("""
            INSERT INTO items (id, kind, created_at, updated_at, device_id, content_hash, preview)
            VALUES (?,?,?,?,?,?,?)
            """,
                   [.text("id-1"), .text("text"), .int(1), .int(1),
                    .text("dev"), .text("hash"), .text("ap-southeast-3-secret")])
        db.close()

        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let asText = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(asText.contains("ap-southeast-3-secret"),
                       "plaintext found in the database file")
        XCTAssertFalse(bytes.prefix(15).elementsEqual(Array("SQLite format 3".utf8)),
                       "file has a plain SQLite header, so it is not encrypted")
    }

    func testTheWrongKeyFailsLoudlyRatherThanReturningNothing() throws {
        let db = try Database(path: path, key: "the-right-key")
        try db.migrate()
        db.close()

        // A wrong key must throw. If it silently returned zero rows, the user
        // would see an empty history and think their data was lost.
        let wrong = try Database(path: path, key: "the-wrong-key")
        XCTAssertThrowsError(try wrong.query("SELECT count(*) AS n FROM items", []))
        wrong.close()
    }

    func testSurvivesCloseAndReopen() throws {
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        try db.run("""
            INSERT INTO items (id, kind, created_at, updated_at, device_id, content_hash, preview)
            VALUES (?,?,?,?,?,?,?)
            """,
                   [.text("id-1"), .text("text"), .int(1), .int(1),
                    .text("dev"), .text("hash"), .text("hello")])
        db.close()

        let reopened = try Database(path: path, key: "test-key")
        let rows = try reopened.query("SELECT preview FROM items", [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["preview"], .text("hello"))
        reopened.close()
    }

    func testBindingRejectsInjection() throws {
        let db = try Database(path: path, key: "test-key")
        try db.migrate()
        // A value containing SQL must be stored as data, never executed.
        let nasty = "'); DROP TABLE items; --"
        try db.run("""
            INSERT INTO items (id, kind, created_at, updated_at, device_id, content_hash, preview)
            VALUES (?,?,?,?,?,?,?)
            """,
                   [.text("id-1"), .text("text"), .int(1), .int(1),
                    .text("dev"), .text("hash"), .text(nasty)])
        let rows = try db.query("SELECT preview FROM items", [])
        XCTAssertEqual(rows[0]["preview"], .text(nasty))
        // The table must still exist.
        XCTAssertNoThrow(try db.query("SELECT count(*) FROM items", []))
        db.close()
    }
}
