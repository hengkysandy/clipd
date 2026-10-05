import Testing
import Foundation
@testable import ClipdCore

/// The derived id for a filing. Both Macs must compute the same one from the
/// same pair without ever exchanging it, which is the whole reason it is
/// derived rather than allocated.
struct MembershipIDTests {
    let itemA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let boardA = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func theSamePairAlwaysGivesTheSameID() {
        #expect(membershipID(item: itemA, board: boardA)
                == membershipID(item: itemA, board: boardA))
    }

    /// The one that would silently corrupt things if it were wrong. Filing
    /// item A on board B is not the same filing as item B on board A, and if
    /// they collided one would overwrite the other in the bucket.
    @Test func theOrderOfThePairMatters() {
        #expect(membershipID(item: itemA, board: boardA)
                != membershipID(item: boardA, board: itemA))
    }

    @Test func differentPairsGiveDifferentIDs() {
        let otherBoard = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        #expect(membershipID(item: itemA, board: boardA)
                != membershipID(item: itemA, board: otherBoard))
    }

    /// It claims to be a name based uuid, so it should look like one to
    /// anything reading the bucket.
    @Test func itIsStampedAsAVersionFiveUUID() {
        let id = membershipID(item: itemA, board: boardA)
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        #expect(bytes[6] & 0xF0 == 0x50, "version nibble should be 5")
        #expect(bytes[8] & 0xC0 == 0x80, "variant bits should be RFC 4122")
    }

    /// A derived id is a wire protocol detail. If it ever changes, two Macs on
    /// different builds compute different ids for the same filing, upload it
    /// twice under different keys and never converge. Pinning one known value
    /// makes that change impossible to make by accident.
    ///
    /// The expected value was computed INDEPENDENTLY, in Python, from the
    /// written rule (sha256 of "clipd-membership-v1:" + the 16 item bytes +
    /// ":" + the 16 board bytes, first 16 bytes, then the version 5 and RFC
    /// 4122 variant bits). It is not a value copied out of this code, so it
    /// checks the implementation rather than agreeing with it.
    @Test func theDerivationIsPinnedToAKnownValue() {
        #expect(membershipID(item: itemA, board: boardA).uuidString
                == "75BAF34F-38CB-5A4F-A30E-68F53E73B7E7")
    }
}
