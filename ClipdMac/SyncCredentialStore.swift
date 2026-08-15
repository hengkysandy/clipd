import Foundation
import Security

/// R2 credentials and the sync passphrase, in the login Keychain.
///
/// Never in a file, never in the repo, never in a log. The `.env.local` file in
/// the repo is for the test suite only and is gitignored; the app does not read
/// it.
enum SyncCredentialStore {
    private static let service = "com.hengkysandy.clipd.mac.sync"
    private static let account = "r2-credentials"

    private struct Stored: Codable {
        let accountID: String
        let accessKeyID: String
        let secretAccessKey: String
        let bucket: String
        let passphrase: String
    }

    static func save(_ credentials: R2Credentials, passphrase: String) throws {
        let stored = Stored(accountID: credentials.accountID,
                            accessKeyID: credentials.accessKeyID,
                            secretAccessKey: credentials.secretAccessKey,
                            bucket: credentials.bucket,
                            passphrase: passphrase)
        let data = try JSONEncoder().encode(stored)
        try clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw R2Error.transport("keychain \(status)") }
    }

    static func load() throws -> (R2Credentials, String)? {
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
        guard status == errSecSuccess, let data = item as? Data else {
            throw R2Error.transport("keychain \(status)")
        }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        return (R2Credentials(accountID: stored.accountID,
                              accessKeyID: stored.accessKeyID,
                              secretAccessKey: stored.secretAccessKey,
                              bucket: stored.bucket), stored.passphrase)
    }

    static func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw R2Error.transport("keychain \(status)")
        }
    }
}
