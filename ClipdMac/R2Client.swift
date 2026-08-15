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

    /// Every key under a prefix, following continuation tokens.
    func list(prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            var parts = ["list-type=2", "max-keys=1000", "prefix=\(Self.encode(prefix))"]
            if let token { parts.append("continuation-token=\(Self.encode(token))") }
            // Query parameters must be sorted by name for the canonical request.
            let query = parts.sorted().joined(separator: "&")

            let (status, data) = try await send("GET", key: "", query: query,
                                                body: Data(), extra: [:])
            guard status == 200 else { throw R2Error.http(status, "LIST \(prefix)") }
            let xml = String(decoding: data, as: UTF8.self)
            keys.append(contentsOf: Self.extract(xml, tag: "Key"))
            token = Self.extract(xml, tag: "NextContinuationToken").first
        } while token != nil
        return keys
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
