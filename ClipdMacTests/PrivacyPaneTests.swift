import XCTest
import AppKit
@testable import ClipdMac

/// The auto-clear explanation grew a sentence about the 90 second hold. These
/// check it really fits, measured from the rendered label, rather than trusting
/// a frame height picked by eye.
@MainActor
final class PrivacyPaneTests: XCTestCase {
    private func explanation() throws -> NSTextField {
        let suite = "clipd-privacy-pane-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pane = PrivacyPane(settings: AppSettings(defaults: defaults))
        pane.loadView()
        let label = pane.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "autoClearExplain" }
        return try XCTUnwrap(label)
    }

    func testTheWholeExplanationFitsItsFrame() throws {
        let label = try explanation()
        let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width,
                                                           height: .greatestFiniteMagnitude)).height
        XCTAssertLessThanOrEqual(needed, label.frame.height,
                                 "the last line of the explanation would be cut off")
    }

    func testItDoesNotOverlapTheHeadingBelowIt() throws {
        let label = try explanation()
        let heading = label.superview?.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Never record copies from" }
        XCTAssertGreaterThanOrEqual(label.frame.minY, try XCTUnwrap(heading).frame.maxY)
    }

    /// It must state the same number the app actually uses.
    func testItStatesTheRealWindow() throws {
        XCTAssertTrue(try explanation().stringValue.contains("90 seconds"))
    }
}
