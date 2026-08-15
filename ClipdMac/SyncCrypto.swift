import Foundation
import CryptoKit
import CommonCrypto

/// End to end encryption for anything that leaves the machine.
///
/// The key is derived from a passphrase the user types on BOTH Macs, so
/// Cloudflare never has it and stores ciphertext it cannot read. That is
/// deliberately different from the local database key, which is random and
/// lives only in the Keychain: this data leaves the machine and that data does
/// not.
enum SyncCrypto {
    enum CryptoError: Error {
        case cannotDecrypt
    }

    /// PBKDF2-SHA256. Rejected: using the passphrase directly as a key, which
    /// would make a short passphrase trivially brute forceable against an
    /// attacker holding the ciphertext.
    static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let passphraseBytes = Array(passphrase.utf8)
        _ = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passphrase, passphraseBytes.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                210_000,
                &derived, derived.count)
        }
        return SymmetricKey(data: Data(derived))
    }

    /// AES-GCM. Authenticated, so tampered ciphertext fails to open rather than
    /// returning wrong bytes, and a fresh nonce each time, so two items with the
    /// same content do not produce identical objects in the bucket.
    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw CryptoError.cannotDecrypt }
        return combined
    }

    static func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        } catch {
            throw CryptoError.cannotDecrypt
        }
    }

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
