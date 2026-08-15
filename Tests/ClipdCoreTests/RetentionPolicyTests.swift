import Testing
import Foundation
@testable import ClipdCore

private let now = Date(timeIntervalSince1970: 1_000_000_000)

private func aged(_ seconds: TimeInterval, id: UUID = UUID()) -> HistoryItem {
    HistoryItem(id: id, text: "item", sourceBundleID: nil, sourceName: nil,
                createdAt: now.addingTimeInterval(-seconds))
}

private let hour: TimeInterval = 3600
private let day = 24 * hour

@Test("Forever expires nothing, however old")
func foreverKeepsEverything() {
    let items = [aged(day * 3650), aged(0)]
    #expect(itemsToExpire(items, policy: .forever, pinned: [], now: now).isEmpty)
}

@Test("Day keeps the last 24 hours and expires the rest")
func dayPolicy() {
    let fresh = aged(hour)
    let stale = aged(day + hour)
    let expired = itemsToExpire([fresh, stale], policy: .day, pinned: [], now: now)
    #expect(expired == [stale.id])
}

@Test("Week, month and year use the ages you would expect")
func longerPolicies() {
    #expect(itemsToExpire([aged(day * 6)], policy: .week, pinned: [], now: now).isEmpty)
    #expect(itemsToExpire([aged(day * 8)], policy: .week, pinned: [], now: now).count == 1)
    #expect(itemsToExpire([aged(day * 29)], policy: .month, pinned: [], now: now).isEmpty)
    #expect(itemsToExpire([aged(day * 31)], policy: .month, pinned: [], now: now).count == 1)
    #expect(itemsToExpire([aged(day * 364)], policy: .year, pinned: [], now: now).isEmpty)
    #expect(itemsToExpire([aged(day * 366)], policy: .year, pinned: [], now: now).count == 1)
}

@Test("A pinned item is never expired, however old")
func pinnedIsExempt() {
    let old = aged(day * 3650)
    // Otherwise a one week setting quietly eats the snippets you deliberately
    // kept, which is the opposite of what pinning means.
    #expect(itemsToExpire([old], policy: .day, pinned: [old.id], now: now).isEmpty)
}

@Test("An item exactly on the boundary is kept, not expired")
func boundaryIsInclusive() {
    // Off by one here silently deletes a day of history. Keeping on the
    // boundary is the safe direction to be wrong in.
    let exactly = aged(day)
    #expect(itemsToExpire([exactly], policy: .day, pinned: [], now: now).isEmpty)
}

@Test("An empty history expires nothing and does not crash")
func emptyHistory() {
    #expect(itemsToExpire([], policy: .day, pinned: [], now: now).isEmpty)
}

@Test("An item created in the future is kept, not expired")
func futureItemIsKept() {
    // Degenerate case: a clock that jumped. Deleting data because the clock
    // moved would be unforgivable.
    let future = aged(-day)
    #expect(itemsToExpire([future], policy: .day, pinned: [], now: now).isEmpty)
}

@Test("Every policy has a label and only forever has no maximum age")
func labelsAndAges() {
    for policy in RetentionPolicy.allCases {
        #expect(!policy.label.isEmpty)
    }
    #expect(RetentionPolicy.forever.maxAge == nil)
    for policy in RetentionPolicy.allCases where policy != .forever {
        #expect(policy.maxAge != nil)
    }
}

@Test("Expiring returns every stale id, not just the first")
func returnsAllExpired() {
    let a = aged(day * 5), b = aged(day * 6), c = aged(hour)
    let expired = Set(itemsToExpire([a, b, c], policy: .day, pinned: [], now: now))
    #expect(expired == Set([a.id, b.id]))
}

@Test("Three and six month policies use the ages you would expect")
func quarterAndHalfYearPolicies() {
    #expect(itemsToExpire([aged(day * 89)], policy: .threeMonths, pinned: [], now: now).isEmpty)
    #expect(itemsToExpire([aged(day * 91)], policy: .threeMonths, pinned: [], now: now).count == 1)
    #expect(itemsToExpire([aged(day * 179)], policy: .sixMonths, pinned: [], now: now).isEmpty)
    #expect(itemsToExpire([aged(day * 181)], policy: .sixMonths, pinned: [], now: now).count == 1)
}

@Test("The policy order runs shortest to longest, which the slider depends on")
func policiesAreOrderedByDuration() {
    // The General pane maps slider positions straight onto allCases, so an
    // out of order case would make the slider jump backwards in time.
    let ages = RetentionPolicy.allCases.compactMap(\.maxAge)
    #expect(ages == ages.sorted())
    #expect(RetentionPolicy.allCases.last == .forever)
}
