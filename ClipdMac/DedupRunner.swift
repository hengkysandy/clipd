import Foundation
import ClipdCore

/// Applies a dedup plan to the store, and reports how many rows were folded.
///
/// Extracted out of the app delegate so a test can drive the real folding code
/// against two stores and one bucket. Rejected: testing `planDedup` alone and
/// trusting the delegate to apply it correctly. The bug that actually shipped
/// was not in the plan, it was in how the plan was applied: the first version
/// hard deleted the losing row, which left its object orphaned in the bucket
/// and let the other Mac hand it straight back on the next sync. A pure test of
/// the plan could never have caught that.
@MainActor
@discardableResult
func applyDedup(in store: SQLiteStore, items: [HistoryItem], pinned: Set<UUID>) throws -> Int {
    let plans = planDedup(items, pinned: pinned)
    guard !plans.isEmpty else { return 0 }

    var folded = 0
    for plan in plans {
        // The survivor takes the newest timestamp in its group, so folding a
        // fresh copy into an older row does not drag the item back down the
        // history, and does not expose it to a retention sweep that would have
        // expired the older copy.
        try store.touch(id: plan.survivor, at: plan.newestCreatedAt)
        for id in plan.doomed {
            // A TOMBSTONE, not a hard delete.
            //
            // A hard delete looked right at first: both Macs fold in the same
            // direction, so neither should need telling. Measured otherwise.
            // The duplicate had already been uploaded, so a hard delete left
            // its object orphaned in the bucket with no tombstone to condemn it
            // (84 objects against 52 local items), AND the other Mac still
            // listed it in its manifest, so the next sync downloaded it
            // straight back.
            //
            // A tombstone is safe precisely because the survivor is chosen by
            // lowest id: both Macs condemn the same row, so a tombstone can
            // never delete the row the other side decided to keep.
            //
            // Stamped NOW, not with the group's newest timestamp. Measured:
            // stamping it with the duplicate's own time made the tombstone tie
            // exactly with the live row still held by the other Mac, and a tie
            // was resolved without ever applying a tombstone. The far Mac kept
            // showing both copies while this one showed one, permanently. A
            // deletion happened at the moment it was decided, so that is the
            // only honest time to record.
            try store.softDelete(id: id, at: Date())
            folded += 1
        }
    }
    return folded
}
