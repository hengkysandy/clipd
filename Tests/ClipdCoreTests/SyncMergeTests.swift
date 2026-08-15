import Testing
import Foundation
@testable import ClipdCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func rec(_ id: UUID, _ updated: TimeInterval, deleted: TimeInterval? = nil,
                 device: String = "A") -> SyncRecord {
    SyncRecord(id: id, updatedAt: t0.addingTimeInterval(updated),
               deletedAt: deleted.map { t0.addingTimeInterval($0) }, deviceID: device)
}

@Test("An item only we have is uploaded")
func uploadsLocalOnly() {
    let id = UUID()
    #expect(planSync(local: [rec(id, 10)], remote: []) == [.upload(id)])
}

@Test("An item only they have is downloaded")
func downloadsRemoteOnly() {
    let id = UUID()
    #expect(planSync(local: [], remote: [rec(id, 10)]) == [.download(id)])
}

@Test("Identical timestamps do nothing")
func identicalDoesNothing() {
    let id = UUID()
    #expect(planSync(local: [rec(id, 10)], remote: [rec(id, 10)]) == [.nothing(id)])
}

@Test("The newer side wins, in both directions")
func lastWriterWins() {
    let id = UUID()
    #expect(planSync(local: [rec(id, 20)], remote: [rec(id, 10)]) == [.upload(id)])
    #expect(planSync(local: [rec(id, 10)], remote: [rec(id, 20)]) == [.download(id)])
}

@Test("A newer remote tombstone is applied, not downloaded as content")
func remoteTombstoneApplies() {
    let id = UUID()
    // Downloading the body of a deleted item would be pointless, and on a
    // slow link it is a wasted multi megabyte transfer for an image.
    #expect(planSync(local: [rec(id, 10)], remote: [rec(id, 20, deleted: 20)])
            == [.applyTombstone(id)])
}

@Test("An older remote tombstone does NOT resurrect as a delete")
func olderTombstoneLoses() {
    let id = UUID()
    // The item was deleted, then edited again later. The edit wins.
    #expect(planSync(local: [rec(id, 30)], remote: [rec(id, 20, deleted: 20)])
            == [.upload(id)])
}

@Test("A local tombstone newer than remote content is uploaded")
func localTombstoneWins() {
    let id = UUID()
    // Without this the other Mac resurrects everything you deleted, which is
    // the single most annoying sync bug there is.
    #expect(planSync(local: [rec(id, 30, deleted: 30)], remote: [rec(id, 10)])
            == [.upload(id)])
}

@Test("Two tombstones do nothing")
func bothDeleted() {
    let id = UUID()
    #expect(planSync(local: [rec(id, 10, deleted: 10)], remote: [rec(id, 10, deleted: 10)])
            == [.nothing(id)])
}

@Test("A tie on timestamp is broken by device id, the same way on both Macs")
func tieBreakIsDeterministic() {
    let id = UUID()
    // Without a deterministic tie break the two Macs disagree forever, each
    // uploading over the other on every pass.
    let a = planSync(local: [rec(id, 10, device: "A")], remote: [rec(id, 10, device: "B")])
    let b = planSync(local: [rec(id, 10, device: "B")], remote: [rec(id, 10, device: "A")])
    #expect(a == [.download(id)])
    #expect(b == [.nothing(id)])
}

@Test("Many items are all planned, and the plan is stable in order")
func manyItems() {
    let ids = (0..<5).map { _ in UUID() }
    let local = [rec(ids[0], 10), rec(ids[1], 30), rec(ids[2], 10)]
    let remote = [rec(ids[1], 10), rec(ids[2], 30), rec(ids[3], 10)]
    let plan = planSync(local: local, remote: remote)
    #expect(plan.count == 4)
    #expect(plan.contains(.upload(ids[0])))
    #expect(plan.contains(.upload(ids[1])))
    #expect(plan.contains(.download(ids[2])))
    #expect(plan.contains(.download(ids[3])))
    // Stable ordering, so a plan can be compared between runs.
    #expect(planSync(local: local, remote: remote) == plan)
}

@Test("A FRESH second Mac downloads everything and deletes nothing")
func joiningASecondMacIsSafe() {
    // The second MacBook, first ever sync: empty local, a full remote history.
    let ids = (0..<4).map { _ in UUID() }
    let remote = ids.enumerated().map { rec($1, Double(10 + $0 * 5)) }
    let plan = planSync(local: [], remote: remote)
    #expect(plan.count == 4)
    // Every single action is a download. Nothing is deleted, ever.
    #expect(plan.allSatisfy { if case .download = $0 { return true } else { return false } })
}

@Test("The FIRST Mac loses nothing when an empty second Mac joins")
func anEmptyPeerNeverDeletesYourHistory() {
    // The other side's manifest says "I have nothing". That is not the same as
    // "you should have nothing", and confusing the two would wipe a real
    // history the first time a second device was set up.
    let ids = (0..<4).map { _ in UUID() }
    let local = ids.map { rec($0, 10) }
    let plan = planSync(local: local, remote: [])
    #expect(plan.count == 4)
    #expect(plan.allSatisfy { if case .upload = $0 { return true } else { return false } })
    // Explicitly: no deletion action of any kind was planned.
    #expect(!plan.contains { if case .applyTombstone = $0 { return true } else { return false } })
}

@Test("Empty on both sides plans nothing")
func emptyBoth() {
    #expect(planSync(local: [], remote: []).isEmpty)
}

@Test("A manifest survives a JSON round trip")
func manifestCodable() throws {
    let manifest = SyncManifest(deviceID: "A", records: [rec(UUID(), 10), rec(UUID(), 20, deleted: 20)])
    let data = try JSONEncoder().encode(manifest)
    #expect(try JSONDecoder().decode(SyncManifest.self, from: data) == manifest)
}
