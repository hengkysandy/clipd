import Testing
import Foundation
@testable import ClipdCore

/// Several remote manifests can list the same item. The merge must keep the
/// NEWEST record, not whichever manifest happened to be listed last.
///
/// Measured in production: a third manifest from a device last seen on
/// 11 September sorts after the live Mac's, so its two month old records
/// replaced the live Mac's current ones. Every pass re-uploaded items the
/// live Mac already had, and a deletion made on the live Mac could never
/// arrive, because the stale record still said "live".
struct StaleManifestTests {
    let id = UUID()
    func at(_ s: Double, deleted: Bool = false, device: String) -> SyncRecord {
        SyncRecord(id: id, updatedAt: Date(timeIntervalSince1970: s),
                   deletedAt: deleted ? Date(timeIntervalSince1970: s) : nil, deviceID: device)
    }

    @Test func aDeletionOnTheLiveMacWinsOverAStaleManifestListedAfterIt() {
        let mine = at(200, device: "this-mac")
        let liveMacDeletedIt = at(300, deleted: true, device: "live-mac")
        let deadDeviceStale = at(100, device: "dead-mac")
        let plan = planSync(local: [mine], remote: [liveMacDeletedIt, deadDeviceStale])
        #expect(plan == [.applyTombstone(id)])
    }

    @Test func aStaleManifestCannotMakeThisMacReuploadWhatTheLiveMacHas() {
        let mine = at(200, device: "this-mac")
        let liveMacHasIt = at(200, device: "this-mac")
        let deadDeviceStale = at(100, device: "dead-mac")
        let plan = planSync(local: [mine], remote: [liveMacHasIt, deadDeviceStale])
        #expect(plan == [.nothing(id)])
    }

    /// Order must not matter at all.
    @Test func theResultIsTheSameWhicheverOrderTheManifestsCameIn() {
        let mine = at(200, device: "this-mac")
        let newer = at(300, deleted: true, device: "live-mac")
        let older = at(100, device: "dead-mac")
        #expect(planSync(local: [mine], remote: [newer, older])
                == planSync(local: [mine], remote: [older, newer]))
    }

    /// Two remote records at the same instant, one a deletion: the deletion
    /// wins, the same rule planSync already applies between this Mac and one
    /// other.
    @Test func onATieBetweenRemotesTheDeletionWins() {
        let mine = at(100, device: "this-mac")
        let live = at(200, device: "mac-1")
        let gone = at(200, deleted: true, device: "mac-2")
        #expect(planSync(local: [mine], remote: [gone, live]) == [.applyTombstone(id)])
        #expect(planSync(local: [mine], remote: [live, gone]) == [.applyTombstone(id)])
    }
}

struct PlanEachItemOnceTests {
    @Test func anItemListedByTwoManifestsIsPlannedOnce() {
        let id = UUID()
        let a = SyncRecord(id: id, updatedAt: Date(timeIntervalSince1970: 1), deletedAt: nil, deviceID: "mac-1")
        let b = SyncRecord(id: id, updatedAt: Date(timeIntervalSince1970: 2), deletedAt: nil, deviceID: "mac-2")
        #expect(planSync(local: [], remote: [a, b]) == [.download(id)])
    }
}

struct AgreedDeletionTests {
    /// Both sides hold a deletion at different times: nothing to exchange in
    /// either direction. Before, the older side re-applied and the newer side
    /// re-uploaded, on every pass, forever.
    @Test func twoTombstonesAtDifferentTimesAreLeftAlone() {
        let id = UUID()
        let early = SyncRecord(id: id, updatedAt: Date(timeIntervalSince1970: 100),
                               deletedAt: Date(timeIntervalSince1970: 100), deviceID: "mac-1")
        let late = SyncRecord(id: id, updatedAt: Date(timeIntervalSince1970: 200),
                              deletedAt: Date(timeIntervalSince1970: 200), deviceID: "mac-2")
        #expect(planSync(local: [early], remote: [late]) == [.nothing(id)])
        #expect(planSync(local: [late], remote: [early]) == [.nothing(id)])
    }
}
