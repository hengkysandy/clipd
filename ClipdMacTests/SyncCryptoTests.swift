import XCTest
import CryptoKit
@testable import ClipdMac

final class SyncCryptoTests: XCTestCase {
    private let salt = Data(repeating: 0x42, count: 32)

    func testRoundTrips() throws {
        let key = SyncCrypto.deriveKey(passphrase: "correct horse", salt: salt)
        let original = Data((0..<10_000).map { UInt8($0 % 251) })
        XCTAssertEqual(try SyncCrypto.open(SyncCrypto.seal(original, with: key), with: key),
                       original)
    }

    func testTheSamePassphraseAndSaltAlwaysGiveTheSameKey() {
        // Both Macs derive independently. If this were not stable, the second
        // Mac could never read anything the first one wrote.
        let a = SyncCrypto.deriveKey(passphrase: "shared secret", salt: salt)
        let b = SyncCrypto.deriveKey(passphrase: "shared secret", salt: salt)
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testADifferentPassphraseGivesADifferentKey() {
        let a = SyncCrypto.deriveKey(passphrase: "one", salt: salt)
        let b = SyncCrypto.deriveKey(passphrase: "two", salt: salt)
        XCTAssertNotEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testADifferentSaltGivesADifferentKey() {
        let a = SyncCrypto.deriveKey(passphrase: "same", salt: salt)
        let b = SyncCrypto.deriveKey(passphrase: "same", salt: Data(repeating: 0x99, count: 32))
        XCTAssertNotEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testTheWrongKeyCannotDecrypt() throws {
        let right = SyncCrypto.deriveKey(passphrase: "right", salt: salt)
        let wrong = SyncCrypto.deriveKey(passphrase: "wrong", salt: salt)
        let sealed = try SyncCrypto.seal(Data("secret".utf8), with: right)
        XCTAssertThrowsError(try SyncCrypto.open(sealed, with: wrong))
    }

    func testTamperedCiphertextIsRejected() throws {
        let key = SyncCrypto.deriveKey(passphrase: "p", salt: salt)
        var sealed = try SyncCrypto.seal(Data("secret".utf8), with: key)
        // AES-GCM is authenticated, so a flipped bit must fail to open rather
        // than returning wrong plaintext.
        sealed[sealed.count / 2] ^= 0x01
        XCTAssertThrowsError(try SyncCrypto.open(sealed, with: key))
    }

    func testCiphertextDoesNotContainThePlaintext() throws {
        let key = SyncCrypto.deriveKey(passphrase: "p", salt: salt)
        let sealed = try SyncCrypto.seal(Data("ap-southeast-3-secret".utf8), with: key)
        // R2 must only ever see ciphertext.
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("ap-southeast-3-secret"))
    }

    func testTwoSealsOfTheSamePlaintextDiffer() throws {
        let key = SyncCrypto.deriveKey(passphrase: "p", salt: salt)
        // A fresh nonce each time. Identical ciphertext would leak that two
        // items have the same content, to anyone who can list the bucket.
        XCTAssertNotEqual(try SyncCrypto.seal(Data("same".utf8), with: key),
                          try SyncCrypto.seal(Data("same".utf8), with: key))
    }

    func testHandlesEmptyAndLargePayloads() throws {
        let key = SyncCrypto.deriveKey(passphrase: "p", salt: salt)
        XCTAssertEqual(try SyncCrypto.open(SyncCrypto.seal(Data(), with: key), with: key), Data())
        // A real screenshot measured at about 2.8 MB.
        let big = Data(repeating: 0x7f, count: 3_000_000)
        XCTAssertEqual(try SyncCrypto.open(SyncCrypto.seal(big, with: key), with: key), big)
    }

    func testRandomSaltIsThirtyTwoBytesAndNotConstant() {
        XCTAssertEqual(SyncCrypto.randomSalt().count, 32)
        XCTAssertNotEqual(SyncCrypto.randomSalt(), SyncCrypto.randomSalt())
    }
}
