import Foundation
import XCTest
@testable import LungfishHTC

final class HTCHelloTests: XCTestCase {
    func testHelloVersionLineAndFileDigest() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("htc-hello-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = HTCCommand.run(arguments: [file.path])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(
            result.standardOutput,
            "lungfish-htc \(HTCCommand.version)\n"
                + "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  \(file.path)\n"
        )
    }
}
