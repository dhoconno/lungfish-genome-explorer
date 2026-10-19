// CLISIGTERMHarnessBurnerTests.swift - The CPU burners of the SIGTERM harness end with the process they follow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 final candidate, fix 3 (CAND.md Step 6, "Orphans first"). The unit tier at H left 29 orphaned
// `/bin/sh -c "while :; do :; done"` burners that ran for 1 h 24 min and raised the load to about 90. A test
// stops its burners in a `defer`, which a burner outlives when the test process dies first, by a crash or by a
// gate's kill. `CLISIGTERMHarness.launchBurners(count:whileRunning:)` starts burners whose loop ends by itself
// once the process they follow is gone. The first case follows a short-lived child `sh` and not this process,
// so the test can watch the end. No tool and no network are needed.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport

final class CLISIGTERMHarnessBurnerTests: XCTestCase {
    /// A short-lived child `sh` stands in for a test process that dies. The burners spin while it runs and end by
    /// themselves, with no stop, soon after it ends.
    func testABurnerEndsByItselfSoonAfterTheProcessItFollowsEnds() async throws {
        let child = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 1"],
            environment: [:]
        )
        defer { child.stop() }
        XCTAssertNotEqual(child.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        let burners = try CLISIGTERMHarness.launchBurners(count: 3, whileRunning: child.processIdentifier)
        defer { burners.forEach { $0.stop() } }
        XCTAssertEqual(burners.count, 3)

        // While the child runs no burner may end. The burners are read before the child, so a burner seen gone
        // beside a child that still runs ended while the child ran.
        var endedEarly = Set<Int32>()
        let childEnded = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            let gone = burners.filter { !$0.isRunning }.map(\.processIdentifier)
            guard !child.isRunning else {
                endedEarly.formUnion(gone)
                return false
            }
            return true
        }
        XCTAssertTrue(childEnded, "the child sh never ended")
        XCTAssertEqual(endedEarly, [], "a burner ended while the process it follows still ran")

        // With the child gone each burner ends by itself within a loop turn, and the wait returns as soon as the
        // last one has.
        let ended = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            burners.allSatisfy { !$0.isRunning }
        }
        XCTAssertTrue(ended, "a burner still ran \(CLISIGTERMHarness.processWait) after the process it follows ended")
    }

    /// A burner given no process follows this one, so it keeps spinning while this process runs, and a stop ends it.
    func testABurnerOfThisProcessRunsUntilItIsStopped() async throws {
        let burners = try CLISIGTERMHarness.launchBurners(count: 2)
        defer { burners.forEach { $0.stop() } }
        // A burner that followed another process would end at its first turn. The wait returns at once on such a
        // burner and otherwise runs out its half second.
        let endedEarly = await waitUntil(timeout: .milliseconds(500), pollInterval: .milliseconds(10)) {
            burners.contains { !$0.isRunning }
        }
        XCTAssertFalse(endedEarly, "a burner ended while the process it follows, this one, still ran")
        burners.forEach { $0.stop() }
        let stopped = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            burners.allSatisfy { !$0.isRunning }
        }
        XCTAssertTrue(stopped, "a stop left a burner running")
    }

    /// `kill -0 0` always succeeds, so a burner given a process group or a negative ID would never end. The helper
    /// refuses such an ID before it starts anything.
    func testABurnerRefusesAProcessIDItCannotFollow() {
        for pid: Int32 in [-1, 0, 1] {
            do {
                let burners = try CLISIGTERMHarness.launchBurners(count: 1, whileRunning: pid)
                burners.forEach { $0.stop() }
                XCTFail("a burner was started for the process ID \(pid)")
            } catch {
                XCTAssertTrue(error is ToolProcessError, "the process ID \(pid) gave \(error)")
            }
        }
    }
}
