import XCTest
import AppKit
import LungfishKit
@testable import LungfishApp

/// NEW-09 (found live with Computer Use): after the user chose
/// "Cancel Operations and Quit", the re-run of the termination gates returned
/// `.terminateNow` but the result was discarded, so AppKit (already told
/// `.terminateLater`) never received a reply and the app never quit.
@MainActor
final class QuitWithRunningOperationsTests: XCTestCase {
    func testConfirmingQuitWithRunningOperationRepliesTrue() async throws {
        let delegate = AppDelegate()
        let operationID = OperationCenter.shared.start(title: "Long running test op", detail: "running")
        defer { OperationCenter.shared.fail(id: operationID, detail: "test cleanup", errorMessage: "test cleanup") }

        var presented: [String] = []
        delegate.testingQuitWithRunningOperationsAnswer = { operations in
            presented = operations.map(\.title)
            return true
        }

        var replies: [Bool] = []
        let immediate = delegate.testingApplicationShouldTerminate { replies.append($0) }
        XCTAssertEqual(immediate, .terminateLater)

        let deadline = Date().addingTimeInterval(5)
        while replies.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(presented.contains("Long running test op"))
        XCTAssertEqual(replies, [true], "confirming must always reach the pending terminate reply")
    }

    func testDeclinedQuitWithRunningOperationRepliesFalse() async throws {
        let delegate = AppDelegate()
        let operationID = OperationCenter.shared.start(title: "Another running test op", detail: "running")
        defer { OperationCenter.shared.fail(id: operationID, detail: "test cleanup", errorMessage: "test cleanup") }
        delegate.testingQuitWithRunningOperationsAnswer = { _ in false }

        var replies: [Bool] = []
        XCTAssertEqual(delegate.testingApplicationShouldTerminate { replies.append($0) }, .terminateLater)
        let deadline = Date().addingTimeInterval(5)
        while replies.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(replies, [false])
    }
}
