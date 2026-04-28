import XCTest
@testable import LungfishApp

final class AsyncRequestGateTests: XCTestCase {
    func testLatestTokenIsCurrentAndOlderTokenIsStale() {
        var gate = AsyncRequestGate<String>()

        let first = gate.begin(identity: "sample-A")
        let second = gate.begin(identity: "sample-B")

        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testInvalidateMakesExistingTokenStale() {
        var gate = AsyncRequestGate<String>()

        let token = gate.begin(identity: "query-A")
        gate.invalidate()

        XCTAssertFalse(gate.isCurrent(token))
    }

    func testIdentityMismatchIsStaleEvenWhenGenerationMatches() {
        var gate = AsyncRequestGate<String>()

        let token = gate.begin(identity: "track-A")

        XCTAssertFalse(gate.isCurrent(token, expectedIdentity: "track-B"))
        XCTAssertTrue(gate.isCurrent(token, expectedIdentity: "track-A"))
    }
}
