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

    /// Every entry point is closed in demo mode, not just the read.
    ///
    /// A demo instance runs against a scratch database but shares the login
    /// Keychain with the real one. Reading would put the real account id into
    /// the settings pane that is about to be screenshotted; writing would let a
    /// form filled in as a prop overwrite the credentials that actually work.
    static func save(_ credentials: R2Credentials, passphrase: String) throws {
        guard !DemoMode.isOn else { return }
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
        guard !DemoMode.isOn else { return nil }
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
        guard !DemoMode.isOn else { return }
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
