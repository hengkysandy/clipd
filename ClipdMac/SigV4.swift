import Foundation
import CryptoKit

/// AWS Signature Version 4, which is what the R2 S3 API requires.
///
/// Rejected: an S3 SDK. This app makes four kinds of request, and the smallest
/// Swift S3 SDK is a very large dependency for PUT, GET, LIST and DELETE.
/// Measured: this hand rolled signer authenticates against R2, 7 of 7 probe
/// checks passing.
struct SigV4 {
    let accessKeyID: String
    let secretAccessKey: String
    let region: String
    let service: String

    /// Returns the headers to add to the request, including Authorization.
    ///
    /// `now` is a parameter rather than read inside, so signing is testable
    /// without the clock moving under the test.
    func sign(method: String, host: String, path: String, query: String,
              headers: [String: String], body: Data, now: Date) -> [String: String] {
        let amzDate = Self.stamp(now, format: "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = Self.stamp(now, format: "yyyyMMdd")
        let payloadHash = Self.hex(SHA256.hash(data: body))

        var all = headers
        all["host"] = host
        all["x-amz-content-sha256"] = payloadHash
        all["x-amz-date"] = amzDate

        // Canonical headers are lowercased, sorted by name, values trimmed.
        let lowered = Dictionary(uniqueKeysWithValues:
            all.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
        let names = lowered.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(lowered[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")

        let canonicalRequest = [
            method, path, query, canonicalHeaders, signedHeaders, payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        ].joined(separator: "\n")

        var key = Self.hmac(Data("AWS4\(secretAccessKey)".utf8), dateStamp)
        key = Self.hmac(key, region)
        key = Self.hmac(key, service)
        key = Self.hmac(key, "aws4_request")
        let signature = Self.hex(Self.hmac(key, stringToSign))

        var out = all
        out["Authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
        return out
    }

    /// Fixed locale and timezone. A locale slip here produces a signature that
    /// fails only for users outside UTC or on a non Gregorian calendar, which
    /// is the worst kind of bug to find in the field.
    private static func stamp(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f.string(from: date)
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
                                             using: SymmetricKey(data: key)))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
