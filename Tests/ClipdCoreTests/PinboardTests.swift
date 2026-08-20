import Testing
import Foundation
@testable import ClipdCore

private func item(_ text: String, at seconds: TimeInterval = 0) -> HistoryItem {
    HistoryItem(text: text, sourceBundleID: nil, sourceName: nil,
                createdAt: Date(timeIntervalSince1970: seconds))
}

@Test("A nil board means the whole history, unfiltered")
func nilBoardShowsEverything() {
    let items = [item("a", at: 200), item("b", at: 100)]
    #expect(itemsOn(nil, items: items, membership: [:]).map(\.text) == ["a", "b"])
}

@Test("A board shows only its own items, in history order")
func boardFilters() {
    let a = item("a", at: 300), b = item("b", at: 200), c = item("c", at: 100)
    let board = Pinboard(id: UUID(), name: "Work", colorName: "blue", sortOrder: 0)
    let membership: [UUID: Set<UUID>] = [board.id: [a.id, c.id]]
    #expect(itemsOn(board, items: [a, b, c], membership: membership).map(\.text) == ["a", "c"])
}

@Test("An empty board shows nothing rather than everything")
func emptyBoardShowsNothing() {
    let board = Pinboard(id: UUID(), name: "Empty", colorName: "red", sortOrder: 0)
    // Falling back to the full history here would be worse than useless: you
    // would think the board had items it does not.
    #expect(itemsOn(board, items: [item("a")], membership: [:]).isEmpty)
}

@Test("An item can be on more than one board")
func itemOnManyBoards() {
    let shared = item("shared")
    let one = Pinboard(id: UUID(), name: "One", colorName: "red", sortOrder: 0)
    let two = Pinboard(id: UUID(), name: "Two", colorName: "blue", sortOrder: 1)
    let membership: [UUID: Set<UUID>] = [one.id: [shared.id], two.id: [shared.id]]
    #expect(itemsOn(one, items: [shared], membership: membership).count == 1)
    #expect(itemsOn(two, items: [shared], membership: membership).count == 1)
}

@Test("Membership naming a missing item does not crash or invent one")
func staleMembershipIsIgnored() {
    // Degenerate case: an item was deleted but its membership row lingers.
    let board = Pinboard(id: UUID(), name: "Board", colorName: "red", sortOrder: 0)
    let membership: [UUID: Set<UUID>] = [board.id: [UUID(), UUID()]]
    #expect(itemsOn(board, items: [item("a")], membership: membership).isEmpty)
}

@Test("Colours cycle and avoid what is already used")
func colourAssignment() {
    #expect(nextColor(after: []) == BoardColor.allCases[0].rawValue)
    #expect(nextColor(after: [BoardColor.allCases[0].rawValue]) == BoardColor.allCases[1].rawValue)
    // Once every colour is used it wraps rather than returning nothing.
    let all = BoardColor.allCases.map(\.rawValue)
    #expect(BoardColor(rawValue: nextColor(after: all)) != nil)
}

@Test("No two boards share a colour until every colour is taken")
func noDuplicatesUntilTheyRunOut() {
    var used: [String] = []
    for _ in BoardColor.allCases {
        let next = nextColor(after: used)
        #expect(!used.contains(next), "\(next) was handed out twice")
        used.append(next)
    }
    #expect(Set(used).count == BoardColor.allCases.count)
}

@Test("Past the end of the palette it spreads evenly rather than counting boards")
func spreadsEvenlyOnceFull() {
    var used = BoardColor.allCases.map(\.rawValue)
    // The eighth board doubles up on the first colour, and the ninth on the
    // second, so the repeats are as far apart as the palette allows.
    used.append(nextColor(after: used))
    #expect(used.last == BoardColor.allCases[0].rawValue)
    used.append(nextColor(after: used))
    #expect(used.last == BoardColor.allCases[1].rawValue)
}

@Test("A deleted board frees its colour, and nothing else moves")
func deletingABoardFreesItsColour() {
    // The old rule wrapped on how many boards existed, so deleting one changed
    // the answer for reasons unrelated to what was on screen. This asks what
    // the remaining boards are actually wearing.
    let all = BoardColor.allCases.map(\.rawValue)
    let afterDeletingTheThird = all.enumerated().filter { $0.offset != 2 }.map(\.element)
    #expect(nextColor(after: afterDeletingTheThird) == BoardColor.allCases[2].rawValue)
}

@Test("A colour that left the palette is still stored and still counted")
func retiredColoursAreNotReassigned() {
    // A board created before red was retired. It keeps its name in the
    // database, and asking for the next colour must not crash or count it.
    let next = nextColor(after: ["red", "blue"])
    #expect(next == BoardColor.purple.rawValue)
    #expect(BoardColor(rawValue: "red") == nil, "red must not come back into rotation")
}

@Test("Every board colour has a name that survives a round trip")
func coloursAreCodable() {
    for colour in BoardColor.allCases {
        #expect(BoardColor(rawValue: colour.rawValue) == colour)
    }
}

@Test("Boards sort by sortOrder, not by name or id")
func boardOrdering() {
    let a = Pinboard(id: UUID(), name: "Zebra", colorName: "red", sortOrder: 0)
    let b = Pinboard(id: UUID(), name: "Apple", colorName: "blue", sortOrder: 1)
    #expect([b, a].sorted { $0.sortOrder < $1.sortOrder }.map(\.name) == ["Zebra", "Apple"])
}
