import XCTest
import AppKit
@testable import ClipdMac
import ClipdCore

/// The palette has to stay tellable apart, and that is a measurable property
/// rather than a matter of taste.
///
/// This exists because it already went wrong: system red and system pink sat 16
/// apart in Lab where every other pair was over 40, and at the size a board dot
/// is drawn, 8 points, two boards looked identical. Nothing in the code said so,
/// because the colours are named rather than numbered, so the names looked
/// different while the pixels did not.
final class BoardColorTests: XCTestCase {

    /// CIE76 in Lab. Close enough for "can a person tell these two dots apart".
    /// Under 10 is hard even side by side, 10 to 20 is a squint, over 25 is a
    /// glance.
    private func distance(_ a: NSColor, _ b: NSColor) -> Double {
        func lab(_ colour: NSColor) -> (Double, Double, Double) {
            let s = colour.usingColorSpace(.sRGB)!
            func linear(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let r = linear(s.redComponent), g = linear(s.greenComponent), b = linear(s.blueComponent)
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : (7.787 * t + 16.0 / 116) }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    /// The threshold. Measured minimum in the current palette is about 45 in
    /// dark and 40 in light (orange against yellow), so 25 leaves real headroom
    /// while still catching another red-and-pink.
    private let minimumDistance = 25.0

    @MainActor
    func testNoTwoBoardColoursLookAlike() {
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            var worst = (Double.greatestFiniteMagnitude, "", "")
            appearance.performAsCurrentDrawingAppearance {
                let palette = BoardColor.allCases
                for i in palette.indices {
                    for j in palette.indices where j > i {
                        let d = distance(BoardTabsView.color(named: palette[i].rawValue),
                                         BoardTabsView.color(named: palette[j].rawValue))
                        if d < worst.0 { worst = (d, palette[i].rawValue, palette[j].rawValue) }
                    }
                }
            }
            XCTAssertGreaterThan(
                worst.0, minimumDistance,
                "\(name.rawValue): \(worst.1) and \(worst.2) are only \(Int(worst.0)) apart. "
                + "Two boards would wear dots nobody can tell apart. Pick a different colour, "
                + "and measure it against every other one rather than guessing.")
        }
    }

    @MainActor
    func testEveryPaletteColourIsActuallyDrawn() {
        // color(named:) falls back to grey for a name it does not know. A new
        // case added to BoardColor without a line in that switch would compile,
        // ship, and quietly draw grey dots.
        let grey = BoardTabsView.color(named: "not-a-colour")
        for colour in BoardColor.allCases {
            XCTAssertNotEqual(BoardTabsView.color(named: colour.rawValue), grey,
                              "\(colour.rawValue) has no case in BoardTabsView.color(named:)")
        }
    }

    @MainActor
    func testARetiredColourStillDrawsAsItself() {
        // Boards created before red left the palette still say "red" in the
        // database. They must keep their colour, not turn grey, and the user
        // never asked for either.
        XCTAssertEqual(BoardTabsView.color(named: "red"), NSColor.systemRed)
        XCTAssertNotEqual(BoardTabsView.color(named: "red"),
                          BoardTabsView.color(named: "not-a-colour"))
    }
}
