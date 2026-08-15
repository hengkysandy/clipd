import XCTest
@testable import ClipdMac

final class DatabaseKeyTests: XCTestCase {
    /// A throwaway service per test run.
    ///
    /// These tests originally used the real service name, which meant running
    /// the suite tried to delete the running app's actual database key. macOS
    /// refused the delete, which is the only reason a real history was not made
    /// permanently unreadable. Never point a destructive test at the live key.
    private var service: String!

    override func setUp() {
        super.setUp()
        service = "com.hengkysandy.clipd.mac.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? DatabaseKey.delete(service: service)
        super.tearDown()
    }

    func testTheTestServiceIsNeverTheRealOne() {
        // A guard against this regressing. If someone drops the parameter,
        // this fails before the destructive tests below run.
        XCTAssertNotEqual(service, DatabaseKey.defaultService)
    }

    func testCreatesAKeyOnFirstUse() throws {
        let key = try DatabaseKey.loadOrCreate(service: service)
        // 32 random bytes hex encoded. Long enough that a brute force is not
        // the weak link, short enough to pass as a PRAGMA argument.
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
    }

    func testReturnsTheSameKeyOnEveryLaterCall() throws {
        let first = try DatabaseKey.loadOrCreate(service: service)
        let second = try DatabaseKey.loadOrCreate(service: service)
        // If this ever fails, every existing history becomes unreadable.
        XCTAssertEqual(first, second)
    }

    func testDeleteRemovesTheKeySoANewOneIsGenerated() throws {
        let first = try DatabaseKey.loadOrCreate(service: service)
        try DatabaseKey.delete(service: service)
        let second = try DatabaseKey.loadOrCreate(service: service)
        XCTAssertNotEqual(first, second)
    }

    func testDeleteOnAMissingKeyIsNotAnError() throws {
        try DatabaseKey.delete(service: service)
        // Degenerate case: deleting twice must not throw.
        XCTAssertNoThrow(try DatabaseKey.delete(service: service))
    }
}
