import XCTest
import ClipdCore

final class SmokeTests: XCTestCase {
    func testCoreIsLinkedIntoTheApp() {
        XCTAssertEqual(ClipdCore.version, "0.8.0")
    }
}
