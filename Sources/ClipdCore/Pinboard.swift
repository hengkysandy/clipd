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
public enum BoardColor: String, CaseIterable, Equatable, Sendable {
    case blue, purple, pink, red, orange, yellow, green
}

/// Picks the next unused colour, wrapping when they are all taken.
///
/// Rejected: a random colour, which produces two near identical dots often
/// enough to be annoying, and is not reproducible in a test.
public func nextColor(after existing: [String]) -> String {
    let used = Set(existing)
    for colour in BoardColor.allCases where !used.contains(colour.rawValue) {
        return colour.rawValue
    }
    // Everything is used. Wrap on count so the choice stays deterministic.
    return BoardColor.allCases[existing.count % BoardColor.allCases.count].rawValue
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
