import Testing
import Foundation
@testable import ClipdCore

private func item(_ text: String, id: UUID = UUID(), at seconds: TimeInterval = 0) -> HistoryItem {
    HistoryItem(id: id, text: text, sourceBundleID: nil, sourceName: nil,
                createdAt: Date(timeIntervalSince1970: seconds))
}

private let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let midID = UUID(uuidString: "50000000-0000-0000-0000-000000000000")!
private let highID = UUID(uuidString: "FF000000-0000-0000-0000-000000000000")!

@Test("Different content is never folded")
func distinctContentIsLeftAlone() {
    #expect(planDedup([item("a"), item("b"), item("c")]).isEmpty)
}

@Test("An empty history plans nothing")
func dedupOnEmptyHistory() {
    #expect(planDedup([]).isEmpty)
}

@Test("A single item plans nothing")
func singleItem() {
    #expect(planDedup([item("only")]).isEmpty)
}

@Test("Two copies of the same text fold into one")
func foldsAPair() {
    let plans = planDedup([item("same", id: highID, at: 200),
                           item("same", id: lowID, at: 100)])
    #expect(plans.count == 1)
    #expect(plans[0].survivor == lowID)
    #expect(plans[0].doomed == [highID])
}

@Test("The survivor is the lowest id, NOT the newest or oldest item")
func survivorIsDeterministicByID() {
    // This is the property that matters most. Both Macs must independently
    // pick the same survivor, or they fold each other's rows in opposite
    // directions forever, each undoing the other on every pass. Clocks differ
    // between devices; a UUID string does not.
    let a = planDedup([item("x", id: highID, at: 500), item("x", id: lowID, at: 100)])
    let b = planDedup([item("x", id: lowID, at: 100), item("x", id: highID, at: 500)])
    #expect(a[0].survivor == lowID)
    #expect(b[0].survivor == lowID)
    #expect(a == b)
}

@Test("The survivor inherits the newest timestamp in the group")
func survivorTakesTheNewestDate() {
    // Otherwise folding a fresh copy into an old one drags the item back down
    // the history and it looks like the recent copy never happened.
    let plans = planDedup([item("same", id: lowID, at: 100),
                           item("same", id: highID, at: 900)])
    #expect(plans[0].newestCreatedAt == Date(timeIntervalSince1970: 900))
}

@Test("Three copies fold into one survivor and two doomed")
func foldsATriple() {
    let plans = planDedup([item("t", id: midID, at: 200),
                           item("t", id: highID, at: 300),
                           item("t", id: lowID, at: 100)])
    #expect(plans.count == 1)
    #expect(plans[0].survivor == lowID)
    #expect(Set(plans[0].doomed) == Set([midID, highID]))
}

@Test("Several duplicate groups are planned independently")
func multipleGroups() {
    let plans = planDedup([item("a", at: 1), item("a", at: 2),
                           item("b", at: 3), item("b", at: 4),
                           item("c", at: 5)])
    #expect(plans.count == 2)
    #expect(plans.allSatisfy { $0.doomed.count == 1 })
}

@Test("A PINNED item always survives, even against a lower id")
func pinnedItemSurvives() {
    // Folding a pinned item away would silently remove it from a board the
    // user filed it on, and leave membership rows pointing at a dead id.
    let plans = planDedup([item("p", id: lowID, at: 100),
                           item("p", id: highID, at: 200)],
                          pinned: [highID])
    #expect(plans[0].survivor == highID)
    #expect(plans[0].doomed == [lowID])
}

@Test("Two pinned copies are BOTH kept rather than one being folded")
func twoPinnedItemsAreLeftAlone() {
    // They may be on different boards. Folding either would break one of them.
    #expect(planDedup([item("p", id: lowID), item("p", id: highID)],
                      pinned: [lowID, highID]).isEmpty)
}

@Test("Images dedup on their content hash, not their id")
func imagesFoldToo() {
    let bytes = Data([1, 2, 3, 4])
    let a = HistoryItem(id: lowID, imageData: bytes, pixelWidth: 10, pixelHeight: 10,
                        sourceBundleID: nil, sourceName: nil,
                        createdAt: Date(timeIntervalSince1970: 100))
    let b = HistoryItem(id: highID, imageData: bytes, pixelWidth: 10, pixelHeight: 10,
                        sourceBundleID: nil, sourceName: nil,
                        createdAt: Date(timeIntervalSince1970: 200))
    let plans = planDedup([a, b])
    #expect(plans.count == 1)
    #expect(plans[0].survivor == lowID)
}

@Test("Different images are not folded together")
func differentImagesStay() {
    let a = HistoryItem(imageData: Data([1, 2, 3]), pixelWidth: 10, pixelHeight: 10,
                        sourceBundleID: nil, sourceName: nil, createdAt: Date())
    let b = HistoryItem(imageData: Data([9, 9, 9]), pixelWidth: 10, pixelHeight: 10,
                        sourceBundleID: nil, sourceName: nil, createdAt: Date())
    #expect(planDedup([a, b]).isEmpty)
}

@Test("Planning twice over the same input gives the same plan")
func planIsStable() {
    let items = [item("s", id: highID, at: 200), item("s", id: lowID, at: 100),
                 item("t", id: midID, at: 300)]
    #expect(planDedup(items) == planDedup(items))
}

@Test("Running dedup on an already deduped history plans nothing")
func convergesAfterOnePass() {
    // Without this the two Macs would keep planning work forever.
    let items = [item("a", id: lowID), item("b", id: highID)]
    #expect(planDedup(items).isEmpty)
}
