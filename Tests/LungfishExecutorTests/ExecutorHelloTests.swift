import Foundation
import XCTest
@testable import LungfishExecutor

final class ExecutorHelloTests: XCTestCase {
    func testHelloVersionLineAndFileDigest() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("executor-hello-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = ExecutorCommand.run(arguments: [file.path])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(
            result.standardOutput,
            "lungfish-executor \(ExecutorCommand.version)\n"
                + "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  \(file.path)\n"
        )
    }
}
