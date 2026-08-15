import XCTest
@testable import ClipdMac

/// Integration tests against a real bucket.
///
/// They skip cleanly when clipd/.env.local is absent, so the suite passes on a
/// machine with no credentials. Rejected: mocking URLSession, which would have
/// proved only that the mock agrees with itself. The whole risk here is whether
/// a real signed request is accepted by a real server.
final class R2ClientTests: XCTestCase {
    private var client: R2Client?
    private let prefix = "clipd-tests/\(UUID().uuidString)/"

    override func setUp() {
        super.setUp()
        guard let creds = Self.loadCredentials() else { return }
        client = R2Client(credentials: creds)
    }

    override func tearDown() async throws {
        if let client {
            for key in (try? await client.list(prefix: prefix)) ?? [] {
                try? await client.delete(key)
            }
        }
        try await super.tearDown()
    }

    /// Exposed so the sync engine tests can reuse the same loader.
    static func loadCredentialsForTests() -> R2Credentials? { loadCredentials() }

    static func loadCredentials() -> R2Credentials? {
        // The test bundle runs from DerivedData, so the repo path is explicit.
        let candidates = [
            FileManager.default.currentDirectoryPath + "/.env.local",
            NSHomeDirectory() + "/claude-chats/mac-paste-app/clipd/.env.local",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            env[String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let a = env["R2_ACCOUNT_ID"], let k = env["R2_ACCESS_KEY_ID"],
              let s = env["R2_SECRET_ACCESS_KEY"], let b = env["R2_BUCKET"] else { return nil }
        return R2Credentials(accountID: a, accessKeyID: k, secretAccessKey: s, bucket: b)
    }

    func testRoundTripsExactBytes() async throws {
        guard let client else { throw XCTSkip("no .env.local, skipping R2 integration test") }
        // Binary, not text. The real payload is AES-GCM ciphertext.
        var payload = Data([0x00, 0xff, 0x10])
        payload.append(Data((0..<5000).map { UInt8($0 % 251) }))
        let key = prefix + "roundtrip.enc"

        _ = try await client.put(key, payload, ifAbsent: false)
        let fetched = try await client.get(key)
        XCTAssertEqual(fetched, payload)
    }

    func testGetOnAMissingKeyReturnsNilRatherThanThrowing() async throws {
        guard let client else { throw XCTSkip("no .env.local") }
        // Missing is a normal outcome during sync, not an error.
        let fetched = try await client.get(prefix + "does-not-exist.enc")
        XCTAssertNil(fetched)
    }

    func testListReturnsOnlyKeysUnderThePrefix() async throws {
        guard let client else { throw XCTSkip("no .env.local") }
        _ = try await client.put(prefix + "a.enc", Data("a".utf8), ifAbsent: false)
        _ = try await client.put(prefix + "b.enc", Data("b".utf8), ifAbsent: false)
        let keys = try await client.list(prefix: prefix)
        XCTAssertEqual(Set(keys), Set([prefix + "a.enc", prefix + "b.enc"]))
    }

    func testListOnAnEmptyPrefixReturnsNothing() async throws {
        guard let client else { throw XCTSkip("no .env.local") }
        let keys = try await client.list(prefix: prefix + "empty/")
        XCTAssertTrue(keys.isEmpty)
    }

    func testIfAbsentCreatesOnceAndThenRefuses() async throws {
        guard let client else { throw XCTSkip("no .env.local") }
        let key = prefix + "once.bin"
        // Measured on R2: If-None-Match returns 412 on the second write. This
        // is how the salt is created exactly once across two Macs.
        let first = try await client.put(key, Data("first".utf8), ifAbsent: true)
        let second = try await client.put(key, Data("second".utf8), ifAbsent: true)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let stored = try await client.get(key)
        XCTAssertEqual(stored, Data("first".utf8))
    }

    func testDeleteRemovesTheObject() async throws {
        guard let client else { throw XCTSkip("no .env.local") }
        let key = prefix + "gone.enc"
        _ = try await client.put(key, Data("x".utf8), ifAbsent: false)
        try await client.delete(key)
        let fetched = try await client.get(key)
        XCTAssertNil(fetched)
    }

    func testABadSecretFailsLoudly() async throws {
        guard let creds = Self.loadCredentials() else { throw XCTSkip("no .env.local") }
        let broken = R2Client(credentials: R2Credentials(
            accountID: creds.accountID, accessKeyID: creds.accessKeyID,
            secretAccessKey: String(creds.secretAccessKey.reversed()), bucket: creds.bucket))
        // A wrong credential must throw, not return an empty list. An empty
        // list would look identical to an empty bucket, and sync would happily
        // conclude the other Mac has nothing.
        do {
            _ = try await broken.list(prefix: prefix)
            XCTFail("expected a throw for a bad secret")
        } catch {
            // expected
        }
    }
}
