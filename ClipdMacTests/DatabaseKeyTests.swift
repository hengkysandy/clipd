import XCTest
@testable import ClipdMac

final class DatabaseKeyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        try? DatabaseKey.delete()
    }

    override func tearDown() {
        try? DatabaseKey.delete()
        super.tearDown()
    }

    func testCreatesAKeyOnFirstUse() throws {
        let key = try DatabaseKey.loadOrCreate()
        // 32 random bytes hex encoded. Long enough that a brute force is not
        // the weak link, short enough to pass as a PRAGMA argument.
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
    }

    func testReturnsTheSameKeyOnEveryLaterCall() throws {
        let first = try DatabaseKey.loadOrCreate()
        let second = try DatabaseKey.loadOrCreate()
        // If this ever fails, every existing history becomes unreadable.
        XCTAssertEqual(first, second)
    }

    func testDeleteRemovesTheKeySoANewOneIsGenerated() throws {
        let first = try DatabaseKey.loadOrCreate()
        try DatabaseKey.delete()
        let second = try DatabaseKey.loadOrCreate()
        XCTAssertNotEqual(first, second)
    }

    func testDeleteOnAMissingKeyIsNotAnError() throws {
        try DatabaseKey.delete()
        // Degenerate case: deleting twice must not throw.
        XCTAssertNoThrow(try DatabaseKey.delete())
    }
}
