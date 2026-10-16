// TeardownBlockOrderTests.swift - When XCTest runs teardown blocks, and the helper that depends on it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import XCTest

/// `makeTestDefaultsSuite(prefix:)` tears its suite down in a teardown block. Its comment said the block runs after
/// the instance `tearDown()`, but XCTest runs it first, so a `tearDown()` that still used the suite wrote the plist
/// again and `SequenceAppearanceTests` left one per test in `$TMPDIR/TestDefaultsSuite` (Phase 2.11 lane Q62, the
/// open note of Q34). The first case proves the order and the second proves the sweep that follows `tearDown()`.
final class TeardownBlockOrderTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        func record(_ event: String) {
            lock.lock()
            recorded.append(event)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    private let events = Events()

    /// Runs after the teardown blocks of the case below, which is the order this class pins.
    override func tearDown() {
        events.record("tearDown")
        if name.contains("testTeardownBlocksRunLastInFirstOutBeforeTheInstanceTearDown") {
            XCTAssertEqual(
                events.all,
                ["test", "block added second", "block added first", "tearDown"],
                "XCTest runs teardown blocks last in, first out, and before the instance tearDown()"
            )
        }
        super.tearDown()
    }

    func testTeardownBlocksRunLastInFirstOutBeforeTheInstanceTearDown() {
        let events = events
        addTeardownBlock { events.record("block added first") }
        addTeardownBlock { events.record("block added second") }
        events.record("test")
    }

    /// A `tearDown()` that still writes to the suite creates the plist again after the block removed it. The
    /// sweeper removes it when the test case finishes, which is after `tearDown()`. The suite comes from
    /// `makeTestDefaultsSuite(prefix:)`, so the test also fails when the helper stops registering its suites.
    func testASuiteThatTearDownWritesToIsRemovedWhenTheTestCaseFinishes() {
        let suite = makeTestDefaultsSuite(prefix: "TeardownBlockOrderTests")

        suite.defaults.set("value", forKey: "key")
        suite.tearDown()
        suite.defaults.set("written by a tearDown() that runs after the block", forKey: "key")
        _ = suite.defaults.synchronize()
        XCTAssertTrue(
            waitUntil { FileManager.default.fileExists(atPath: suite.plistURL.path) },
            "the system never wrote \(suite.plistURL.path), so the test cannot show the sweep removes it"
        )

        TestDefaultsSuiteSweeper.shared.testCaseDidFinish(self)

        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.plistURL.path), "left \(suite.plistURL.path)")
        XCTAssertNil(suite.defaults.string(forKey: "key"), "the sweep empties the domain too")
    }

    /// A case that registered no suite leaves the sweeper with nothing to do.
    func testFinishingACaseWithNoSuiteIsHarmless() {
        TestDefaultsSuiteSweeper.shared.testCaseDidFinish(self)
    }

    // MARK: - Helpers

    /// Polls `condition` every 50 ms and returns true as soon as it holds, false at the timeout.
    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}
