import Testing
import Foundation
@testable import ClipdCore

/// The board tab and the retention sweep now call these directly, so they get
/// their own tests rather than relying on History.search's.
struct SharedRulesTests {
    private func item(_ text: String, title: String? = nil, age: TimeInterval = 0) -> HistoryItem {
        HistoryItem(text: text, sourceBundleID: nil, sourceName: nil,
                    createdAt: Date(timeIntervalSince1970: 1_000_000 - age), title: title)
    }

    /// The board tab must match exactly what the Clipboard tab matches, or a
    /// word finds a card in one place and not the other.
    @Test func filterByQueryAgreesWithHistorySearch() {
        let items = [item("ADCB IBAN AE65"), item("kubectl get pods"),
                     item("1465", title: "ADCB Customer ID")]
        let history = History()
        history.load(items)
        for query in ["adcb", "ADCB customer", "pods", "", "nothing here", "ae65 adcb"] {
            #expect(filterByQuery(items, query).map(\.id) == history.search(query).map(\.id),
                    "disagreement on \(query)")
        }
    }

    @Test func anEmptyQueryReturnsEverythingInOrder() {
        let items = [item("a"), item("b"), item("c")]
        #expect(filterByQuery(items, "   ").map(\.id) == items.map(\.id))
    }

    @Test func idsToExpireMatchesItemsToExpire() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let items = [item("fresh", age: 60), item("old", age: 3 * 86_400), item("pinned old", age: 3 * 86_400)]
        let pinned: Set<UUID> = [items[2].id]
        let viaItems = itemsToExpire(items, policy: .day, pinned: pinned, now: now)
        let viaIDs = idsToExpire(items.map { (id: $0.id, createdAt: $0.createdAt) },
                                 policy: .day, pinned: pinned, now: now)
        #expect(viaItems == viaIDs)
        #expect(viaIDs == [items[1].id])
    }
}
