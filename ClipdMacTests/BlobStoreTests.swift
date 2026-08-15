import XCTest
import CryptoKit
@testable import ClipdMac

final class BlobStoreTests: XCTestCase {
    private var dir: URL!
    private var store: BlobStore!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-blobs-\(UUID().uuidString)")
        let key = BlobStore.symmetricKey(fromHex: String(repeating: "ab", count: 32))
        store = BlobStore(directory: dir, key: key)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testRoundTrips() throws {
        let original = Data("a pretend png payload".utf8)
        let ref = try store.write(original, id: UUID())
        XCTAssertEqual(try store.read(ref), original)
    }

    func testTheFileOnDiskIsNotThePlaintext() throws {
        let original = Data("SECRET-SCREENSHOT-CONTENT".utf8)
        let ref = try store.write(original, id: UUID())
        let onDisk = try Data(contentsOf: dir.appendingPathComponent(ref))
        let asText = String(decoding: onDisk, as: UTF8.self)
        // An unencrypted screenshot beside an encrypted database would be a
        // pointless gap, and a screenshot of a password manager is exactly
        // what lands there.
        XCTAssertFalse(asText.contains("SECRET-SCREENSHOT-CONTENT"))
        XCTAssertNotEqual(onDisk, original)
    }

    func testADifferentKeyCannotRead() throws {
        let ref = try store.write(Data("payload".utf8), id: UUID())
        let other = BlobStore(directory: dir,
                              key: BlobStore.symmetricKey(fromHex: String(repeating: "cd", count: 32)))
        XCTAssertThrowsError(try other.read(ref))
    }

    func testDeleteRemovesTheFile() throws {
        let ref = try store.write(Data("payload".utf8), id: UUID())
        try store.delete(ref)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ref).path))
        XCTAssertThrowsError(try store.read(ref))
    }

    func testDeletingSomethingMissingIsNotAnError() throws {
        // Degenerate case: a retention sweep and a manual delete race.
        XCTAssertNoThrow(try store.delete("does-not-exist.enc"))
    }

    func testHandlesAnEmptyPayload() throws {
        let ref = try store.write(Data(), id: UUID())
        XCTAssertEqual(try store.read(ref), Data())
    }

    func testHandlesAMultiMegabytePayload() throws {
        // A real screenshot measured at about 2.8 MB.
        let big = Data(repeating: 0x7f, count: 3_000_000)
        let ref = try store.write(big, id: UUID())
        XCTAssertEqual(try store.read(ref), big)
    }
}
