// ToolProcessMainQueueMeasureTests.swift - Where XCTest runs a test method, as a main-queue precondition sees it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// Phase 2.13 lane 13.05 measure. A `#if DEBUG`
/// `dispatchPrecondition(condition: .notOnQueue(.main))` in the blocking calls
/// of ToolProcess traps every test that reaches them from the main queue. The
/// main queue is bound to the main thread, so a value set on it with
/// `setSpecific` is what `getSpecific` reads on that thread, which is the
/// queue a precondition checks. These tests record where a synchronous and an
/// async test method run, so the precondition lands only if neither runs there.
final class ToolProcessMainQueueMeasureTests: XCTestCase {
    private static let mainQueueKey = DispatchSpecificKey<String>()

    override class func setUp() {
        super.setUp()
        DispatchQueue.main.setSpecific(key: mainQueueKey, value: "main")
    }

    private static func measure(_ method: String) -> (mainThread: Bool, mainQueue: Bool) {
        let mainThread = Thread.isMainThread
        let mainQueue = DispatchQueue.getSpecific(key: mainQueueKey) == "main"
        print("ToolProcessMainQueueMeasure \(method) mainThread=\(mainThread) mainQueue=\(mainQueue)")
        return (mainThread, mainQueue)
    }

    /// XCTest runs a synchronous test method on the main thread, so it is on
    /// the main queue.
    func testSynchronousTestMethodRunsOnTheMainQueue() {
        let measured = Self.measure("synchronous")
        XCTAssertTrue(measured.mainThread)
        XCTAssertTrue(measured.mainQueue)
    }

    /// An async test method of a class that is not main-actor isolated runs
    /// on the cooperative pool, off the main queue.
    func testAsyncTestMethodRunsOffTheMainQueue() async {
        let measured = Self.measure("async")
        XCTAssertFalse(measured.mainThread)
        XCTAssertFalse(measured.mainQueue)
    }
}
