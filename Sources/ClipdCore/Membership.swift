import Foundation
import CryptoKit

/// The sync id for "this item is filed on this board".
///
/// A membership is identified by a PAIR, but everything else that syncs is
/// identified by a single UUID, and `planSync`, the manifest and the bucket
/// keys are all built on that. Deriving one UUID from the pair lets memberships
/// use the whole existing pipeline unchanged rather than growing a parallel
/// one beside it.
///
/// Deterministic, so both Macs compute the same id for the same filing without
/// ever exchanging it. That is the entire point: there is no central place to
/// allocate an id, and two Macs that disagreed about the id would each upload
/// the same filing under a different key and never converge.
///
/// The order is fixed, item first and then board, with a separator between
/// them, so filing item A on board B cannot collide with filing item B on
/// board A.
///
/// Rejected: joining the two uuid strings and using that as the key directly.
/// It works and needs no hashing, but it makes every bucket key 73 characters
/// and makes memberships the one record type in the manifest with a different
/// shape of id, which is exactly the special case this avoids.
public func membershipID(item: UUID, board: UUID) -> UUID {
    var hasher = SHA256()
    // A version tag in the input. If the derivation ever has to change, the
    // ids change with it, which is correct: old and new must not be confused.
    hasher.update(data: Data("clipd-membership-v1:".utf8))
    withUnsafeBytes(of: item.uuid) { hasher.update(bufferPointer: $0) }
    hasher.update(data: Data(":".utf8))
    withUnsafeBytes(of: board.uuid) { hasher.update(bufferPointer: $0) }

    var bytes = Array(hasher.finalize().prefix(16))
    // Stamp the version 5 (name based) and variant bits, because that is
    // honestly what this is, and a tool reading the bucket should not be told
    // it is a random uuid.
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) })
}
