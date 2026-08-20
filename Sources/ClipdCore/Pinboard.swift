import Foundation

/// A named, colour tagged board. A board is a LABEL, not a container: deleting
/// one never deletes the items that were on it.
public struct Pinboard: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var colorName: String
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, colorName: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.sortOrder = sortOrder
    }
}

/// The palette, matching the coloured dots in the reference app.
///
/// Names rather than raw colour values, so the actual shade is the shell's
/// business and Core stays free of AppKit.
///
/// `red` was here and is not any more. Measured in Lab: system red and system
/// pink are 16 apart in dark mode and 15 in light, where every other pair in
/// this palette is over 40. At the size these are drawn, an 8 point dot, that is
/// two boards you cannot tell apart. Teal replaced it because it scored furthest
/// from every survivor of the six, 66 in both appearances.
///
/// A board created before the change still says "red" in the database, and
/// still draws red. See `BoardTabsView.color(named:)`. Retiring a colour from
/// the palette is not the same as deleting it from history.
public enum BoardColor: String, CaseIterable, Equatable, Sendable {
    case blue, purple, pink, teal, orange, yellow, green
}

/// Picks the next colour: an unused one if there is one, otherwise the one used
/// least.
///
/// Rejected: a random colour, which produces two near identical dots often
/// enough to be annoying, and is not reproducible in a test.
///
/// Rejected: the old rule, which wrapped on `existing.count` once every colour
/// was taken. It counted boards rather than looking at which colours were
/// actually on them, so deleting a board changed the answer for reasons that
/// had nothing to do with what was on screen. Least used is the same answer in
/// the ordinary case and a defensible one in every other.
///
/// Beyond seven boards a repeat is unavoidable, so the goal stops being "never
/// twice" and becomes "as evenly as possible".
public func nextColor(after existing: [String]) -> String {
    var counts: [String: Int] = [:]
    for colour in BoardColor.allCases { counts[colour.rawValue] = 0 }
    for name in existing where counts[name] != nil { counts[name]! += 1 }
    // allCases order breaks ties, so the answer is the same every time and a
    // test can state it.
    var best = BoardColor.allCases[0].rawValue
    for colour in BoardColor.allCases where counts[colour.rawValue]! < counts[best]! {
        best = colour.rawValue
    }
    return best
}

/// The items to show for a board, or the whole history when the board is nil.
///
/// Pure, and takes membership as a plain dictionary, so every filtering case is
/// testable with no database.
public func itemsOn(_ board: Pinboard?,
                    items: [HistoryItem],
                    membership: [UUID: Set<UUID>]) -> [HistoryItem] {
    guard let board else { return items }
    // An unknown board id yields an empty set, so an empty board shows nothing.
    // Falling back to the full history would be worse than useless: you would
    // think the board held items it does not.
    let ids = membership[board.id] ?? []
    return items.filter { ids.contains($0.id) }
}
