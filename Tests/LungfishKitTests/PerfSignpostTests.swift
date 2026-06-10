import XCTest
@testable import LungfishKit

final class PerfSignpostTests: XCTestCase {
    func testIntervalBeginReturnsActiveStateThatCanEnd() {
        // The helper must hand back a state we can later end, exercising the
        // begin/end pairing without needing Instruments attached.
        let signpost = PerfSignpost(category: "Test")
        let state = signpost.begin("UnitInterval")
        // Ending must not trap and must accept the state we were given.
        signpost.end("UnitInterval", state)
    }

    func testEmitEventDoesNotTrap() {
        let signpost = PerfSignpost(category: "Test")
        signpost.event("PointEvent")
    }
}
