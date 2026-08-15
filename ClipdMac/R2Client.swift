import Foundation

struct R2Credentials: Equatable {
    let accountID: String
    let accessKeyID: String
    let secretAccessKey: String
    let bucket: String

    var host: String { "\(accountID).r2.cloudflarestorage.com" }
}

enum R2Error: Error {
    case http(Int, String)
    case transport(String)
}

/// Four verbs against the R2 S3 API. An actor because sync runs off the main
/// thread and must not be re-entered while a pass is in flight.
actor R2Client {
    private let credentials: R2Credentials
    private let signer: SigV4

    init(credentials: R2Credentials) {
        self.credentials = credentials
        // R2 always uses region "auto".
        self.signer = SigV4(accessKeyID: credentials.accessKeyID,
                            secretAccessKey: credentials.secretAccessKey,
                            region: "auto", service: "s3")
    }

    /// Returns true if written. With `ifAbsent`, false means it already existed.
    @discardableResult
    func put(_ key: String, _ body: Data, ifAbsent: Bool = false) async throws -> Bool {
        var extra: [String: String] = [:]
        // Measured on R2: this returns 412 on a second write, giving
        // create-if-absent. Used so two Macs cannot both create the salt.
        if ifAbsent { extra["if-none-match"] = "*" }
        let (status, _) = try await send("PUT", key: key, query: "", body: body, extra: extra)
        if status == 412 { return false }
        guard status == 200 else { throw R2Error.http(status, "PUT \(key)") }
        return true
    }

    /// Nil means the object is not there, which is a normal sync outcome rather
    /// than an error.
    func get(_ key: String) async throws -> Data? {
        let (status, data) = try await send("GET", key: key, query: "", body: Data(), extra: [:])
        if status == 404 { return nil }
        guard status == 200 else { throw R2Error.http(status, "GET \(key)") }
        return data
    }

    func delete(_ key: String) async throws {
        let (status, _) = try await send("DELETE", key: key, query: "", body: Data(), extra: [:])
        // 404 is fine: the caller wanted it gone and it is gone.
        guard status == 204 || status == 200 || status == 404 else {
            throw R2Error.http(status, "DELETE \(key)")
        }
    }

    /// Every key under a prefix, following continuation tokens to the end.
    ///
    /// S3 and R2 cap a single ListObjectsV2 response at 1000 keys. Without the
    /// loop the prune step stops seeing most of the bucket past that point and
    /// never throws, so the bucket grows forever and nothing looks wrong.
    ///
    /// `pageSize` exists only so a test can force real continuation tokens out
    /// of the server without writing 1001 objects. Callers leave it alone.
    func list(prefix: String, pageSize: Int = 1000) async throws -> [String] {
        try await Self.collectKeys { [self] token in
            let query = Self.listQuery(prefix: prefix, pageSize: pageSize,
                                       continuationToken: token)
            let (status, data) = try await send("GET", key: "", query: query,
                                                body: Data(), extra: [:])
            guard status == 200 else { throw R2Error.http(status, "LIST \(prefix)") }
            return Self.parseListPage(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Listing, split out so it can be tested without a network call

    /// One ListObjectsV2 response, reduced to the three things the loop needs.
    struct ListPage: Equatable, Sendable {
        var keys: [String] = []
        var isTruncated: Bool = false
        var nextToken: String?
    }

    /// The canonical query string for one page of a listing.
    ///
    /// Two rules matter here and both have bitten this project. Parameters are
    /// sorted by name, because SigV4 signs them sorted. And every value is
    /// percent encoded exactly once, by `encode`, before it reaches either the
    /// signer or the URL. A continuation token is base64, so it routinely holds
    /// `/`, `+` and `=`, which must become `%2F`, `%2B` and `%3D`. Encoding it
    /// twice, or not at all, produces SignatureDoesNotMatch, which reads like a
    /// bad key rather than a bad string.
    static func listQuery(prefix: String, pageSize: Int = 1000,
                          continuationToken: String?) -> String {
        var pairs = [("list-type", "2"), ("max-keys", String(pageSize)), ("prefix", prefix)]
        if let continuationToken, !continuationToken.isEmpty {
            pairs.append(("continuation-token", continuationToken))
        }
        // Sort on the name alone. Sorting the joined strings happens to give the
        // same answer for these four names, but it would quietly stop doing so
        // if a name ever became a prefix of another name.
        return pairs.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\(encode($0.1))" }
            .joined(separator: "&")
    }

    /// Pulls the keys, the truncation flag and the next token out of the XML.
    ///
    /// Rejected: XMLParser. This response has three fields worth reading and a
    /// delegate based parser would be more code than the scan below. `<Key>` is
    /// matched with its angle brackets, so `<KeyCount>` cannot be mistaken for
    /// it.
    static func parseListPage(_ xml: String) -> ListPage {
        var page = ListPage()
        page.keys = extract(xml, tag: "Key").map(unescapeXML)
        // A missing IsTruncated means false. S3 always sends it, but treating
        // absence as "there is more" would turn a malformed response into an
        // endless loop.
        page.isTruncated = extract(xml, tag: "IsTruncated")
            .first?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        // The token is base64 in practice, but it is still XML text, so it goes
        // through the same unescaping as the keys.
        let token = extract(xml, tag: "NextContinuationToken").first.map(unescapeXML)
        page.nextToken = (token?.isEmpty == false) ? token : nil
        return page
    }

    /// Walks pages until the server says there are no more.
    ///
    /// Kept separate from `list` so the stopping rules can be tested against a
    /// fake page source. Every stop is a break rather than a throw: the two
    /// callers, the manifest loop and the prune step, only ever skip work when
    /// the list is short. Neither of them deletes anything because a key is
    /// missing, so a partial list is safe in this direction, while a throw
    /// would abort a sync pass that was otherwise fine.
    static func collectKeys(
        maxPages: Int = 10_000,
        fetch: @Sendable (String?) async throws -> ListPage
    ) async rethrows -> [String] {
        var keys: [String] = []
        var token: String?
        var seen = Set<String>()

        for _ in 0..<maxPages {
            let page = try await fetch(token)
            keys.append(contentsOf: page.keys)

            guard page.isTruncated else { break }
            // Truncated with no token: there is no way to ask for the rest, so
            // repeating the same request would just fetch page one forever.
            guard let next = page.nextToken else { break }
            // A repeated token means the server is cycling. Same reasoning: the
            // next request would return a page we already have.
            guard seen.insert(next).inserted else { break }
            token = next
        }
        return keys
    }

    /// The five predefined XML entities. `&amp;` is last on purpose, otherwise
    /// a literal `&amp;lt;` in a key would be unescaped twice.
    private static func unescapeXML(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var out = value
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out
    }

    // MARK: - Plumbing

    private func send(_ method: String, key: String, query: String,
                      body: Data, extra: [String: String]) async throws -> (Int, Data) {
        let path = "/\(credentials.bucket)" + (key.isEmpty ? "" : "/" + Self.encodePath(key))
        let headers = signer.sign(method: method, host: credentials.host, path: path,
                                  query: query, headers: extra, body: body, now: Date())

        var components = URLComponents()
        components.scheme = "https"
        components.host = credentials.host
        components.percentEncodedPath = path
        // percentEncodedQuery, NEVER query. Setting .query re-encodes, so a
        // prefix containing %2F becomes %252F and the URL stops matching the
        // canonical request that was signed. Measured: it fails only on
        // requests with an encoded query, which looks like a permissions bug.
        if !query.isEmpty { components.percentEncodedQuery = query }

        guard let url = components.url else { throw R2Error.transport("bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !body.isEmpty { request.httpBody = body }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (status, data)
        } catch {
            throw R2Error.transport(error.localizedDescription)
        }
    }

    /// Percent encoding for a query value. Everything unreserved stays, and a
    /// slash becomes %2F, which is what the canonical request expects.
    private static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Same, but slashes are separators and stay literal.
    private static func encodePath(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }.joined(separator: "/")
    }

    private static func extract(_ xml: String, tag: String) -> [String] {
        var out: [String] = []
        var rest = Substring(xml)
        while let open = rest.range(of: "<\(tag)>"),
              let close = rest.range(of: "</\(tag)>", range: open.upperBound..<rest.endIndex) {
            out.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return out
    }
}
