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
    func testTheFirstSuiteOfAProcessMadeOffTheMainThreadSignsTheSweeperUp() async throws {
        XCTAssertFalse(Self.runsOnTheMainThread(), "precondition: a nonisolated async test runs off the main thread")

        let suite = makeTestDefaultsSuite(prefix: "TestDefaultsSuiteObserverThreadTests")

        suite.defaults.set("value", forKey: "key")
        XCTAssertEqual(suite.defaults.string(forKey: "key"), "value")
    }

    // MARK: - Helpers

    /// A plain function, since `Thread.isMainThread` is unavailable inside an `async` body.
    private static func runsOnTheMainThread() -> Bool {
        Thread.isMainThread
    }
}
