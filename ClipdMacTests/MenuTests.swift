import XCTest
import AppKit
@testable import ClipdMac

/// One line, and it exists because the fix is invisible in the code it protects.
final class MenuIconTests: XCTestCase {
    func testSettingsActionIsNotNamedTheOneMacOSDecorates() {
        // Measured with a throwaway status menu on macOS 26: an item whose
        // action selector is called `openSettings` gets an automatic gear, and
        // one icon indents every other item in the menu. The title makes no
        // difference. Renaming the selector back would quietly bring it back,
        // and nothing else in the code would look wrong.
        XCTAssertFalse(AppDelegate.instancesRespond(to: Selector(("openSettings"))),
                       "macOS draws a gear beside an openSettings item. Use another name.")
        XCTAssertTrue(AppDelegate.instancesRespond(to: Selector(("presentSettings"))),
                      "the Settings menu item has no action to call")
    }
}
