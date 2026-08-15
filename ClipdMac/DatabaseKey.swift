import Foundation
import Security

/// The SQLCipher passphrase, held in the login Keychain.
///
/// Rejected: deriving the key from a user passphrase in v1. That would mean
/// prompting on every launch and losing the entire history if the passphrase
/// is forgotten. A random key in the Keychain is protected by the login
/// password and by FileVault, which is the right level for a local history.
/// v1.1 sync adds a separate user passphrase for the R2 payload, because that
/// data leaves the machine and this key does not.
enum DatabaseKey {
    private static let service = "com.hengkysandy.clipd.mac"
    private static let account = "database-key"

    enum KeyError: Error {
        case unexpectedStatus(OSStatus)
        case malformedData
    }

    static func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        let key = randomHexKey()
        try store(key)
        return key
    }

    private static func randomHexKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // SecRandomCopyBytes, not Int.random. This key protects everything the
        // user has ever copied.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyError.unexpectedStatus(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeyError.malformedData
        }
        return key
    }

    private static func store(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            // Available after first unlock, not "always". The app is not
            // useful before the user logs in anyway.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.unexpectedStatus(status) }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Not found is success: the caller wanted it gone and it is gone.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.unexpectedStatus(status)
        }
    }
}
