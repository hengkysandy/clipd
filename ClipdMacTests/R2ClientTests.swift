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

    // MARK: - Pagination, no network needed

    /// A page that says there is more, in the shape R2 actually returns.
    private func truncatedPageXML(token: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>example-bucket</Name>
          <Prefix>items/</Prefix>
          <KeyCount>2</KeyCount>
          <MaxKeys>1000</MaxKeys>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>\(token)</NextContinuationToken>
          <Contents>
            <Key>items/aaa.enc</Key>
            <LastModified>2026-08-15T10:00:00.000Z</LastModified>
            <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag>
            <Size>17</Size>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <Contents>
            <Key>items/bbb.enc</Key>
            <LastModified>2026-08-15T10:00:01.000Z</LastModified>
            <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag>
            <Size>19</Size>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
        </ListBucketResult>
        """
    }

    func testParsesATruncatedPageWithItsToken() {
        let page = R2Client.parseListPage(truncatedPageXML(token: "1/abc+de=="))
        XCTAssertEqual(page.keys, ["items/aaa.enc", "items/bbb.enc"])
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.nextToken, "1/abc+de==")
    }

    func testParsesAFinalPageAsNotTruncated() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>example-bucket</Name>
          <KeyCount>1</KeyCount>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>items/zzz.enc</Key>
            <Size>3</Size>
          </Contents>
        </ListBucketResult>
        """
        let page = R2Client.parseListPage(xml)
        XCTAssertEqual(page.keys, ["items/zzz.enc"])
        XCTAssertFalse(page.isTruncated)
        XCTAssertNil(page.nextToken)
    }

    func testParsesAnEmptyResultAndIgnoresKeyCount() {
        // KeyCount is the trap here. A parser matching "Key" without the angle
        // brackets would return "0" as if it were an object key, and the prune
        // step would then try to delete a key called "0".
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>example-bucket</Name>
          <Prefix>items/empty/</Prefix>
          <KeyCount>0</KeyCount>
          <MaxKeys>1000</MaxKeys>
          <IsTruncated>false</IsTruncated>
        </ListBucketResult>
        """
        let page = R2Client.parseListPage(xml)
        XCTAssertEqual(page.keys, [])
        XCTAssertFalse(page.isTruncated)
        XCTAssertNil(page.nextToken)
    }

    func testAMissingTruncationFlagIsReadAsFinished() {
        // A malformed response must end the loop, not extend it.
        let page = R2Client.parseListPage("<ListBucketResult></ListBucketResult>")
        XCTAssertFalse(page.isTruncated)
        XCTAssertTrue(page.keys.isEmpty)
    }

    func testAnEmptyTokenIsTreatedAsNoToken() {
        let xml = """
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken></NextContinuationToken>
        </ListBucketResult>
        """
        XCTAssertNil(R2Client.parseListPage(xml).nextToken)
    }

    func testEscapedCharactersInAKeyAreDecoded() {
        let xml = "<ListBucketResult><Contents><Key>items/a&amp;b.enc</Key></Contents>"
            + "<IsTruncated>false</IsTruncated></ListBucketResult>"
        XCTAssertEqual(R2Client.parseListPage(xml).keys, ["items/a&b.enc"])
    }

    func testFirstPageQueryIsSortedAndCarriesNoToken() {
        let query = R2Client.listQuery(prefix: "items/", continuationToken: nil)
        // Sorted by name, because that is the order SigV4 signs.
        XCTAssertEqual(query, "list-type=2&max-keys=1000&prefix=items%2F")
    }

    func testATokenWithSlashAndPlusIsEncodedExactlyOnce() {
        // The whole bug in one test. A base64 token holds "/", "+" and "=".
        // Encoding it zero times breaks the signature, encoding it twice turns
        // %2F into %252F and R2 answers 403, which reads like a bad key.
        let token = "1/abc+def/ghi=="
        let query = R2Client.listQuery(prefix: "items/", continuationToken: token)
        XCTAssertEqual(query,
                       "continuation-token=1%2Fabc%2Bdef%2Fghi%3D%3D"
                       + "&list-type=2&max-keys=1000&prefix=items%2F")
        XCTAssertFalse(query.contains("%25"), "double encoded")
    }

    func testTheSignerSeesTheEncodedQueryUnchanged() {
        // SigV4 must sign the exact bytes that go on the wire. This pins the
        // canonical query string so a future change to listQuery cannot drift
        // away from what the URL carries.
        let query = R2Client.listQuery(prefix: "items/", continuationToken: "a/b+c=")
        let signer = SigV4(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secretexample",
                           region: "auto", service: "s3")
        let headers = signer.sign(method: "GET", host: "example.r2.cloudflarestorage.com",
                                  path: "/example-bucket", query: query, headers: [:],
                                  body: Data(), now: Date(timeIntervalSince1970: 1_700_000_000))
        // A different signature for a differently encoded query proves the
        // query is really an input to the signature, not decoration.
        let other = signer.sign(method: "GET", host: "example.r2.cloudflarestorage.com",
                                path: "/example-bucket",
                                query: query.replacingOccurrences(of: "%2F", with: "%252F"),
                                headers: [:], body: Data(),
                                now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotEqual(headers["Authorization"], other["Authorization"])
    }

    func testCollectKeysFollowsEveryPageInOrder() async {
        let fake = FakePages([
            R2Client.ListPage(keys: ["a", "b"], isTruncated: true, nextToken: "t1"),
            R2Client.ListPage(keys: ["c"], isTruncated: true, nextToken: "t2"),
            R2Client.ListPage(keys: ["d"], isTruncated: false, nextToken: nil),
        ])
        let keys = await R2Client.collectKeys { await fake.next($0) }
        XCTAssertEqual(keys, ["a", "b", "c", "d"])
        // The first request carries no token, then each token is echoed back.
        let seen = await fake.tokensSeen
        XCTAssertEqual(seen, [nil, "t1", "t2"])
    }

    func testCollectKeysReturnsNothingForAnEmptyListing() async {
        let fake = FakePages([R2Client.ListPage()])
        let keys = await R2Client.collectKeys { await fake.next($0) }
        XCTAssertEqual(keys, [])
    }

    func testCollectKeysStopsWhenTruncatedWithNoToken() async {
        // There is no way to ask for the rest, so looping would refetch page one
        // forever inside a single sync pass.
        let fake = FakePages([
            R2Client.ListPage(keys: ["a"], isTruncated: true, nextToken: nil),
        ])
        let keys = await R2Client.collectKeys { await fake.next($0) }
        XCTAssertEqual(keys, ["a"])
        let seen = await fake.tokensSeen
        XCTAssertEqual(seen.count, 1)
    }

    func testCollectKeysStopsWhenTheServerRepeatsAToken() async {
        let fake = FakePages([
            R2Client.ListPage(keys: ["a"], isTruncated: true, nextToken: "same"),
            R2Client.ListPage(keys: ["b"], isTruncated: true, nextToken: "same"),
        ])
        let keys = await R2Client.collectKeys { await fake.next($0) }
        XCTAssertEqual(keys, ["a", "b"])
        let seen = await fake.tokensSeen
        XCTAssertEqual(seen, [nil, "same"])
    }

    func testCollectKeysStopsAtThePageCap() async {
        // A server that always says "more, here is a fresh token" must not hang
        // the sync pass.
        let endless = EndlessPages()
        let keys = await R2Client.collectKeys(maxPages: 4) { await endless.next($0) }
        XCTAssertEqual(keys, ["k1", "k2", "k3", "k4"])
    }

    // MARK: - Pagination against the real bucket

    func testListPagesThroughRealContinuationTokens() async throws {
        guard let client else { throw XCTSkip("no .env.local") }
        // A page size of 1 forces R2 to hand back real tokens, so this covers
        // the one thing a parsing test cannot: that an encoded token still
        // signs. Writing 1001 objects would prove the same thing far slower.
        // The prefix is the per-test throwaway one, never items/ or manifests/.
        let expected = Set((0..<3).map { prefix + "page\($0).enc" })
        for key in expected.sorted() {
            _ = try await client.put(key, Data("x".utf8), ifAbsent: false)
        }
        let keys = try await client.list(prefix: prefix, pageSize: 1)
        XCTAssertEqual(Set(keys), expected)
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

/// A scripted page source for the loop tests.
///
/// An actor rather than a plain class with a counter, because the fetch closure
/// is `@Sendable` and Swift 6 will not let it mutate a captured local variable.
/// Running out of pages returns an empty final page, so a loop that overruns
/// shows up as a wrong token trail rather than a crash.
private actor FakePages {
    private let pages: [R2Client.ListPage]
    private var index = 0
    private(set) var tokensSeen: [String?] = []

    init(_ pages: [R2Client.ListPage]) { self.pages = pages }

    func next(_ token: String?) -> R2Client.ListPage {
        tokensSeen.append(token)
        defer { index += 1 }
        return index < pages.count ? pages[index] : R2Client.ListPage()
    }
}

/// A server that never admits it is finished, used to prove the page cap holds.
private actor EndlessPages {
    private var count = 0

    func next(_ token: String?) -> R2Client.ListPage {
        count += 1
        return R2Client.ListPage(keys: ["k\(count)"], isTruncated: true,
                                 nextToken: "token-\(count)")
    }
}
