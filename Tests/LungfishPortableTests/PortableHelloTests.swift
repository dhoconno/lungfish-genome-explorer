import Foundation
import XCTest
import LungfishPortable

final class PortableHelloTests: XCTestCase {
    /// FIPS 180-2 test vector for the message "abc".
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testHelloDigestOfBytesAndFileAgree() throws {
        XCTAssertEqual(PortableDigest.sha256Hex(of: Data("abc".utf8)), abcDigest)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-hello-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try PortableDigest.sha256Hex(ofFileAt: file), abcDigest)
    }
}
