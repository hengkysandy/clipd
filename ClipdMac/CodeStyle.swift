import AppKit
import ClipdCore

/// The colours and the font for a code card.
///
/// Everything here is presentation, which is why it is in the shell and not in
/// Core. Core decides WHAT a run of text is; this file decides what colour that
/// is on a dark card.
///
/// The palette follows Xcode's default dark theme in spirit, lightened a little.
/// Xcode paints on near black, and a Clipd card is not always near black: a
/// pinned card washes its background with its board colour at 14% alpha over
/// white 0.13. The worst case is the yellow board, which lands at roughly white
/// 0.25. Every colour below was picked to stay legible on that, which mostly
/// meant raising the comment grey and the string salmon a few steps. Rejected:
/// reading the board colour and computing a contrasting palette per card, which
/// is a lot of machinery for a wash that never gets brighter than 0.25.
@MainActor
enum CodeStyle {
    /// 11pt monospaced fits 12 lines in the 166pt tall body area with room to
    /// spare. Measured at 12pt: only 10 lines fitted and the last one clipped.
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let maximumLines = 12

    /// One source line stays one card line, truncated at the right edge.
    ///
    /// Word wrapping was the alternative and it is worse for code: a single
    /// eighty character line wraps three times and eats a quarter of the card,
    /// so the snippet's shape, which is the whole point of this feature,
    /// disappears. If this ever collapses the label to a single line on some
    /// macOS version, change this one value to `.byCharWrapping`.
    static let lineBreak: NSLineBreakMode = .byTruncatingTail

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .plain:       return rgb(0xE6E6E6)
        case .keyword:     return rgb(0xFF7AB2)
        case .type:        return rgb(0xD3BBFF)
        case .string:      return rgb(0xFF9E80)
        case .number:      return rgb(0xE8C77E)
        case .comment:     return rgb(0x93A1AF)
        case .key:         return rgb(0x7EC8FF)
        case .punctuation: return rgb(0xBFC6CE)
        case .emphasis:    return rgb(0xFFD479)
        }
    }

    /// Turns Core's tokens into something a label can draw.
    ///
    /// Runs are appended in order, so the result is the tokens joined, which
    /// Core guarantees is the input text exactly. There is no range arithmetic
    /// here on purpose: that is the class of bug the token design removes.
    static func attributedString(for tokens: [SyntaxToken]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        // A little air between lines, because monospaced glyphs at 11pt sit
        // tight and a dense block is hard to scan at a glance.
        paragraph.lineSpacing = 1

        let out = NSMutableAttributedString()
        for token in tokens {
            out.append(NSAttributedString(string: token.text, attributes: [
                .font: font,
                .foregroundColor: color(for: token.kind),
                .paragraphStyle: paragraph,
            ]))
        }
        return out
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
