import Foundation
import CryptoKit

/// Image payloads, encrypted, one file each.
///
/// Rejected: storing image bytes in the database. They arrive already
/// compressed at around 2.8 MB, so every row would carry megabytes and every
/// query would drag them along.
///
/// Rejected: leaving the files in the clear and relying on FileVault. A
/// screenshot of a password manager or a bank page is exactly what lands here,
/// and an unencrypted folder beside an encrypted database is a pointless gap.
final class BlobStore {
    private let directory: URL
    private let key: SymmetricKey

    enum BlobError: Error {
        case notFound(String)
        case decryptionFailed(String)
    }

    init(directory: URL, key: SymmetricKey) {
        self.directory = directory
        self.key = key
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            // Owner only. The database key protects the contents, but there is
            // no reason for other accounts to see even the file sizes.
            attributes: [.posixPermissions: 0o700])
    }

    /// Derives the blob key from the same hex the database uses.
    ///
    /// One secret to manage rather than two. AES-GCM and SQLCipher use it very
    /// differently, so sharing the input is not a key-reuse problem in the way
    /// reusing a stream cipher keystream would be.
    static func symmetricKey(fromHex hex: String) -> SymmetricKey {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        // SHA256 so any input length yields a valid 256 bit key.
        return SymmetricKey(data: SHA256.hash(data: Data(bytes)))
    }

    @discardableResult
    func write(_ data: Data, id: UUID) throws -> String {
        let ref = "\(id.uuidString).enc"
        // AES-GCM: authenticated, so a corrupted or tampered file fails to open
        // rather than returning wrong bytes.
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw BlobError.decryptionFailed(ref)
        }
        try combined.write(to: directory.appendingPathComponent(ref), options: .atomic)
        return ref
    }

    func read(_ ref: String) throws -> Data {
        let url = directory.appendingPathComponent(ref)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BlobError.notFound(ref)
        }
        let combined = try Data(contentsOf: url)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw BlobError.decryptionFailed(ref)
        }
    }

    func delete(_ ref: String) throws {
        let url = directory.appendingPathComponent(ref)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
