// MappingRouteRowBarTests.swift - The Map Reads bar that the parity and freeze checks compare
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

/// QA's ruling D9 on lane A46 M3. After the bar reached 1, the viewer's step back to 0.93 and up
/// to 1 reaches the panel on one run and not the next, on either route, so
/// ``MappingRouteRow/comparableBar(_:)`` drops that last pair and nothing else.
final class MappingRouteRowBarTests: XCTestCase {
    func testTheViewersReturnAfterTheTopIsDropped() {
        XCTAssertEqual(MappingRouteRow.comparableBar(["0.9000", "1.0000", "0.9300", "1.0000"]), ["0.9000", "1.0000"])
    }

    func testABarThatEndsAtTheTopStaysWhole() {
        XCTAssertEqual(MappingRouteRow.comparableBar(["0.9000", "1.0000"]), ["0.9000", "1.0000"])
    }

    func testAReturnThatIsNotTheLastPairStaysWhole() {
        XCTAssertEqual(
            MappingRouteRow.comparableBar(["1.0000", "0.9300", "0.9600", "1.0000"]),
            ["1.0000", "0.9300", "0.9600", "1.0000"]
        )
    }
}
