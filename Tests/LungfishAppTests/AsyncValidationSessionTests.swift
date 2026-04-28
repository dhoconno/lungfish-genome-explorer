import XCTest
@testable import LungfishApp

final class AsyncValidationSessionTests: XCTestCase {
    func testLatestInputResultIsAccepted() {
        var session = AsyncValidationSession<String, Int>()

        let first = session.begin(input: "path-A")
        let second = session.begin(input: "path-B")

        XCTAssertFalse(session.shouldAccept(resultFor: first))
        XCTAssertTrue(session.shouldAccept(resultFor: second))
    }

    func testCancelRejectsPendingResults() {
        var session = AsyncValidationSession<String, Int>()

        let token = session.begin(input: "query")
        session.cancel()

        XCTAssertFalse(session.shouldAccept(resultFor: token))
    }
}
