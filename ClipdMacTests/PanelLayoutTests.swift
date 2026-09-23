import XCTest
import AppKit
import ClipdCore
@testable import ClipdMac

/// The panel is built once, at launch, and then shown on whatever screen is
/// main at the time. These tests exist because nothing used to resize it with
/// the window, so it stayed laid out for the screen the app was launched on.
@MainActor
final class PanelLayoutTests: XCTestCase {

    // MARK: - The frame math

    /// The one that broke. The card strip is the full width of the panel, so a
    /// strip narrower than its window leaves cards hanging off the edge.
    func testCardStripSpansTheWholePanelAtEveryWidth() {
        for width in [1440, 1470, 1728, 2560, 3840] as [CGFloat] {
            let frame = PanelController.scrollFrame(width: width)
            XCTAssertEqual(frame.width, width,
                           "card strip must fill a \(width) point panel")
            XCTAssertEqual(frame.minX, 0)
        }
    }

    func testBoardTabsKeepTheirRightMarginOnAnyScreen() {
        for width in [1470, 2560, 3840] as [CGFloat] {
            let frame = PanelController.tabsFrame(width: width)
            XCTAssertEqual(width - frame.maxX, 30, accuracy: 0.001,
                           "tabs must stay 30 points off the right edge at \(width)")
        }
    }

    func testBannerIsInsetEquallyOnBothSides() {
        for width in [1470, 2560] as [CGFloat] {
            let frame = PanelController.bannerFrame(width: width)
            XCTAssertEqual(frame.minX, 22)
            XCTAssertEqual(width - frame.maxX, 22, accuracy: 0.001)
        }
    }

    func testEmptyLabelSpansTheWholePanelSoItStaysCentred() {
        for width in [1470, 2560] as [CGFloat] {
            let frame = PanelController.emptyLabelFrame(width: width)
            XCTAssertEqual(frame.minX, 0)
            XCTAssertEqual(frame.width, width)
        }
    }

    /// Not a real Mac, but a zero or negative width view is an AppKit
    /// exception rather than a cosmetic problem, so the floors have to hold.
    func testFramesStayPositiveOnAnAbsurdlyNarrowPanel() {
        let narrow: CGFloat = 320
        for frame in [PanelController.tabsFrame(width: narrow),
                      PanelController.bannerFrame(width: narrow),
                      PanelController.scrollFrame(width: narrow),
                      PanelController.emptyLabelFrame(width: narrow)] {
            XCTAssertGreaterThan(frame.width, 0)
        }
    }

    // MARK: - The resize reaching the real views

    /// The actual regression. The frame math was never wrong. Nothing called
    /// it a second time when the panel moved to a wider screen.
    func testRelayoutMovesTheRealViewsToTheNewWidth() {
        let controller = PanelController(history: History())
        controller.relayout(to: 2560)

        XCTAssertEqual(controller.scroll.frame.width, 2560)
        XCTAssertEqual(controller.emptyLabel.frame.width, 2560)
        XCTAssertEqual(controller.banner.frame.width, 2560 - 44)
        XCTAssertEqual(2560 - controller.tabs.frame.maxX, 30, accuracy: 0.001)
    }

    /// Going the other way matters just as much. Open on the 27 inch monitor,
    /// then unplug and open on the laptop, and a strip that never shrinks
    /// hangs a thousand points off the right edge of the smaller screen.
    func testRelayoutShrinksAsWellAsGrows() {
        let controller = PanelController(history: History())
        controller.relayout(to: 2560)
        controller.relayout(to: 1470)

        XCTAssertEqual(controller.scroll.frame.width, 1470)
        XCTAssertEqual(controller.banner.frame.width, 1470 - 44)
    }

    /// Named for what the bug report actually showed. With a 250 point card,
    /// 12 point gaps and a 22 point section inset at each end, a 1470 point
    /// strip fits five whole cards and cuts the sixth. That is the screenshot.
    /// A 2560 point monitor has to be worth more cards, or the fix bought
    /// nothing.
    func testAWiderPanelIsWorthMoreWholeCards() {
        func wholeCards(in width: CGFloat) -> Int {
            let usable = width - 44
            return Int((usable + 12) / (CardItem.size.width + 12))
        }
        XCTAssertEqual(wholeCards(in: 1470), 5, "the laptop, and the screenshot")
        XCTAssertEqual(wholeCards(in: 2560), 9, "the 27 inch monitor")
        XCTAssertGreaterThan(wholeCards(in: 2560), wholeCards(in: 1470))
    }
}

/// The end to end half. Everything in PanelLayoutTests above checks a piece in
/// isolation; the original bug was that nothing joined the pieces up, so it
/// needs its own test at the level where the joining happens.
@MainActor
final class PanelOpensOnTheRightScreenTests: XCTestCase {

    /// This is the test that would have caught the reported bug. It pretends a
    /// 2560 point monitor is attached, opens the panel the way the hotkey does,
    /// and checks the card strip matches the window it lives in.
    func testShowResizesTheStripToTheScreenItOpensOn() {
        let controller = PanelController(history: History())
        controller.screenFrame = { NSRect(x: 0, y: 0, width: 2560, height: 1440) }

        controller.show()
        defer { controller.panel.orderOut(nil) }

        XCTAssertEqual(controller.panel.frame.width, 2560)
        XCTAssertEqual(controller.scroll.frame.width, controller.panel.frame.width,
                       "the card strip must fill the window it lives in")
        XCTAssertEqual(controller.emptyLabel.frame.width, controller.panel.frame.width)
    }

    /// Unplugging the monitor is the same bug pointing the other way: a strip
    /// that grew to 2560 and never shrank hangs off the laptop's right edge.
    func testReopeningOnASmallerScreenShrinksTheStrip() {
        let controller = PanelController(history: History())

        controller.screenFrame = { NSRect(x: 0, y: 0, width: 2560, height: 1440) }
        controller.show()
        XCTAssertEqual(controller.scroll.frame.width, 2560)

        controller.screenFrame = { NSRect(x: 0, y: 0, width: 1470, height: 956) }
        controller.show()
        defer { controller.panel.orderOut(nil) }

        XCTAssertEqual(controller.panel.frame.width, 1470)
        XCTAssertEqual(controller.scroll.frame.width, 1470,
                       "the strip must shrink as well as grow")
    }
}
