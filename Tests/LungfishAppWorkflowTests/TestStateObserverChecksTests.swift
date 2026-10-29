// TestStateObserverChecksTests.swift - This app-hosted bundle runs the row and window checks of the observer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport

/// Phase 3.1 ruling QA-RELEASE-LOOP, section 4. Each of the three app-hosted bundles runs every check. The row and
/// window checks live in LungfishKitTestSupport, which this bundle links, and the pending-tasks check needs
/// LungfishAppTests' own types, so it stays there.
final class TestStateObserverChecksTests: XCTestCase {
    func testTheBootstrapRegistersTheRowAndWindowChecksInThisBundle() {
        XCTAssertNotNil(TestStateObserver.installedAt, "the bootstrap constructor did not install the observer")
        XCTAssertEqual(TestStateObserver.checkNames,
                       ["xctest defaults", "LUNGFISH_ environment", "current directory", "operation rows",
                        "visible key windows"])
    }
}
