// TestDefaultsSuiteObserverThreadTests.swift - The sweeper's XCTest sign-up when the first suite is made off the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import XCTest

/// `makeTestDefaultsSuite(prefix:)` signs `TestDefaultsSuiteSweeper` up with XCTest the first time a process makes
/// a suite. XCTest throws `NSInternalInconsistencyException` ("Test observers can only be registered and
/// unregistered on the main thread") when another thread does it, and a nonisolated `async` test runs on a
/// cooperative thread. The first such test of a process that made a suite therefore aborted the process, which took
/// down `SRAWindowDownloadSourceTests`, `HumanScrubberDatabaseTests` and `SiblingRootDatabaseCloneTests` in the
/// parallel unit tier (Phase 2.11 tier 1, cause D2). Q62 M2 had moved the sign-up into the lazy initializer of
/// `TestDefaultsSuiteSweeper.shared`, and a serial or single-class run passed because a synchronous test on the
/// main thread had made the first suite.
///
/// The case only exercises the sign-up when it is the first to make a suite in its process, so run it alone with
/// `swift test --filter TestDefaultsSuiteObserverThreadTests`. The class holds this one case for the same reason,
/// because the parallel tier gives each class its own process.
final class TestDefaultsSuiteObserverThreadTests: XCTestCase {
    private var suite: TestDefaultsSuite?

    /// The case of Q62: a `tearDown()` that still writes to the suite creates its plist again after the teardown
    /// block removed it. Only the sweeper removes it once the case finishes, so a plist named for this class that
    /// stays in `$TMPDIR/TestDefaultsSuite` after the run shows that the sweeper never heard of this case.
    override func tearDown() {
        if let suite {
            suite.defaults.set("written by tearDown() after the block", forKey: "late")
            _ = suite.defaults.synchronize()
        }
        super.tearDown()
    }

    func testTheFirstSuiteOfAProcessMadeOffTheMainThreadSignsTheSweeperUp() async throws {
        XCTAssertFalse(Self.runsOnTheMainThread(), "precondition: a nonisolated async test runs off the main thread")

        let suite = makeTestDefaultsSuite(prefix: "TestDefaultsSuiteObserverThreadTests")
        self.suite = suite

        suite.defaults.set("value", forKey: "key")
        XCTAssertEqual(suite.defaults.string(forKey: "key"), "value")
        let signedUp = await Self.eventually { TestDefaultsSuiteSweeper.shared.isObserving }
        XCTAssertTrue(signedUp, "XCTest never got the sweeper as an observer, so no sweep follows tearDown()")
    }

    // MARK: - Helpers

    /// A plain function, since `Thread.isMainThread` is unavailable inside an `async` body.
    private static func runsOnTheMainThread() -> Bool {
        Thread.isMainThread
    }

    /// Polls `condition` every 10 ms and returns as soon as it holds, or false after 30 seconds.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
