import Testing
import Foundation
@testable import ClipdCore

/// Dedup and retention run one after the other at launch and after every sync.
/// Each is correct on its own. The risk is in the pair: dedup keeps the OLDEST
/// id, retention deletes by AGE, so a careless version folds the copy you made
/// a minute ago into a row dated six weeks back and the next sweep expires it.
/// The item would vanish minutes after being copied, which reads as data loss.
private let lowID  = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let highID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 24 * 3600) }

private func item(_ text: String, id: UUID, at date: Date) -> HistoryItem {
    HistoryItem(id: id, text: text, sourceBundleID: nil, sourceName: nil, createdAt: date)
}

/// Applies a plan the way the store does: the survivor takes the newest date,
/// and the losing rows disappear from the visible history.
private func applying(_ plans: [DedupPlan], to items: [HistoryItem]) -> [HistoryItem] {
    let doomed = Set(plans.flatMap(\.doomed))
    let newDate = Dictionary(uniqueKeysWithValues: plans.map { ($0.survivor, $0.newestCreatedAt) })
    return items
        .filter { !doomed.contains($0.id) }
        .map { row in
            guard let date = newDate[row.id] else { return row }
            return item(row.text, id: row.id, at: date)
        }
}

@Test("A copy made just now survives, even folded into a six week old row")
func freshDuplicateSurvivesAggressiveRetention() {
    let old = item("deploy staging", id: lowID, at: daysAgo(42))
    let fresh = item("deploy staging", id: highID, at: now)

    // Before folding, the old row is exactly what a one month policy expires.
    #expect(itemsToExpire([old, fresh], policy: .month, pinned: [], now: now) == [lowID])

    let survivors = applying(planDedup([old, fresh]), to: [old, fresh])
    #expect(survivors.map(\.id) == [lowID])

    // After folding there is nothing to expire, because the surviving row now
    // carries the fresh timestamp. Without that inheritance this is [lowID],
    // and the text the user copied a minute ago is deleted.
    #expect(itemsToExpire(survivors, policy: .month, pinned: [], now: now).isEmpty)
}

@Test("Folding does not rescue a group that is genuinely old")
func oldGroupStillExpires() {
    // The opposite failure: dedup must not act as a way of resetting the clock
    // on things you have not touched in months.
    let a = item("stale", id: lowID, at: daysAgo(100))
    let b = item("stale", id: highID, at: daysAgo(95))
    let survivors = applying(planDedup([a, b]), to: [a, b])
    #expect(itemsToExpire(survivors, policy: .month, pinned: [], now: now) == [lowID])
}

@Test("Either order of the two sweeps keeps the text in the history")
func orderOfSweepsDoesNotLoseTheItem() {
    // The app runs dedup then retention. Nothing enforces that, and a sync can
    // land between them, so the safe property is that BOTH orders leave a live
    // copy of the text.
    let old = item("keep me", id: lowID, at: daysAgo(42))
    let fresh = item("keep me", id: highID, at: now)

    let dedupFirst = applying(planDedup([old, fresh]), to: [old, fresh])
    let afterA = dedupFirst.filter {
        !itemsToExpire(dedupFirst, policy: .month, pinned: [], now: now).contains($0.id)
    }

    let expired = Set(itemsToExpire([old, fresh], policy: .month, pinned: [], now: now))
    let kept = [old, fresh].filter { !expired.contains($0.id) }
    let afterB = applying(planDedup(kept), to: kept)

    #expect(afterA.map(\.text) == ["keep me"])
    #expect(afterB.map(\.text) == ["keep me"])
}

@Test("A pinned survivor is never expired by retention")
func pinnedSurvivorIsNeverExpired() {
    // Two ways to lose a filed item at once: dedup could fold it away, and
    // retention could then expire what is left. Pinning has to beat both.
    let old = item("pinned", id: lowID, at: daysAgo(400))
    let older = item("pinned", id: highID, at: daysAgo(500))
    let plans = planDedup([old, older], pinned: [highID])
    #expect(plans[0].survivor == highID)

    let survivors = applying(plans, to: [old, older])
    #expect(itemsToExpire(survivors, policy: .day, pinned: [highID], now: now).isEmpty)
}

@Test("Retention deleting one copy does not leave dedup planning work forever")
func noWorkLeftAfterBothSweeps() {
    // If the two sweeps could each undo the other's decision they would run on
    // every launch and every sync for the life of the app.
    let rows = [item("x", id: lowID, at: daysAgo(42)), item("x", id: highID, at: now)]
    let survivors = applying(planDedup(rows), to: rows)
    let alive = survivors.filter {
        !itemsToExpire(survivors, policy: .month, pinned: [], now: now).contains($0.id)
    }
    #expect(planDedup(alive).isEmpty)
}
