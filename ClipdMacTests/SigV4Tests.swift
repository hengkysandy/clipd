import XCTest
@testable import ClipdMac

final class SigV4Tests: XCTestCase {
    private let signer = SigV4(accessKeyID: "AKIDEXAMPLE",
                               secretAccessKey: "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
                               region: "auto", service: "s3")
    private let fixedDate = Date(timeIntervalSince1970: 1_440_938_160) // 2015-08-30T12:36:00Z

    func testProducesTheThreeRequiredHeaders() {
        let headers = signer.sign(method: "GET", host: "example.r2.cloudflarestorage.com",
                                  path: "/bucket", query: "", headers: [:],
                                  body: Data(), now: fixedDate)
        XCTAssertNotNil(headers["Authorization"])
        XCTAssertNotNil(headers["x-amz-date"])
        XCTAssertNotNil(headers["x-amz-content-sha256"])
    }

    func testTheDateHeaderIsBasicISO8601InUTC() {
        let headers = signer.sign(method: "GET", host: "h", path: "/b", query: "",
                                  headers: [:], body: Data(), now: fixedDate)
        // The format is exact. A locale or timezone slip here produces a
        // signature that fails only for users outside UTC, which is the worst
        // kind of bug to find in the field.
        XCTAssertEqual(headers["x-amz-date"], "20150830T123600Z")
    }

    func testTheAuthorizationHeaderHasTheExpectedShape() {
        let headers = signer.sign(method: "GET", host: "h", path: "/b", query: "",
                                  headers: [:], body: Data(), now: fixedDate)
        let auth = headers["Authorization"] ?? ""
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 "))
        XCTAssertTrue(auth.contains("Credential=AKIDEXAMPLE/20150830/auto/s3/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        XCTAssertTrue(auth.contains("Signature="))
    }

    func testAnEmptyBodyHashesToTheKnownSHA256OfNothing() {
        let headers = signer.sign(method: "GET", host: "h", path: "/b", query: "",
                                  headers: [:], body: Data(), now: fixedDate)
        // The published SHA256 of the empty string. If this is wrong, every
        // request with no body fails and the cause is invisible.
        XCTAssertEqual(headers["x-amz-content-sha256"],
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSigningIsDeterministic() {
        let a = signer.sign(method: "PUT", host: "h", path: "/b/k", query: "",
                            headers: [:], body: Data("x".utf8), now: fixedDate)
        let b = signer.sign(method: "PUT", host: "h", path: "/b/k", query: "",
                            headers: [:], body: Data("x".utf8), now: fixedDate)
        XCTAssertEqual(a["Authorization"], b["Authorization"])
    }

    func testAnyChangeToTheRequestChangesTheSignature() {
        let base = signer.sign(method: "PUT", host: "h", path: "/b/k", query: "",
                               headers: [:], body: Data("x".utf8), now: fixedDate)["Authorization"]
        let otherMethod = signer.sign(method: "GET", host: "h", path: "/b/k", query: "",
                                      headers: [:], body: Data("x".utf8), now: fixedDate)["Authorization"]
        let otherPath = signer.sign(method: "PUT", host: "h", path: "/b/other", query: "",
                                    headers: [:], body: Data("x".utf8), now: fixedDate)["Authorization"]
        let otherBody = signer.sign(method: "PUT", host: "h", path: "/b/k", query: "",
                                    headers: [:], body: Data("y".utf8), now: fixedDate)["Authorization"]
        let otherQuery = signer.sign(method: "PUT", host: "h", path: "/b/k", query: "a=1",
                                     headers: [:], body: Data("x".utf8), now: fixedDate)["Authorization"]
        XCTAssertNotEqual(base, otherMethod)
        XCTAssertNotEqual(base, otherPath)
        XCTAssertNotEqual(base, otherBody)
        XCTAssertNotEqual(base, otherQuery)
    }

    func testADifferentSecretGivesADifferentSignature() {
        let other = SigV4(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "different",
                          region: "auto", service: "s3")
        XCTAssertNotEqual(
            signer.sign(method: "GET", host: "h", path: "/b", query: "", headers: [:],
                        body: Data(), now: fixedDate)["Authorization"],
            other.sign(method: "GET", host: "h", path: "/b", query: "", headers: [:],
                       body: Data(), now: fixedDate)["Authorization"])
    }

    func testExtraHeadersAreIncludedInSignedHeadersInSortedOrder() {
        let headers = signer.sign(method: "PUT", host: "h", path: "/b/k", query: "",
                                  headers: ["If-None-Match": "*"], body: Data(),
                                  now: fixedDate)
        let auth = headers["Authorization"] ?? ""
        XCTAssertTrue(auth.contains("SignedHeaders=host;if-none-match;x-amz-content-sha256;x-amz-date"))
    }
}
