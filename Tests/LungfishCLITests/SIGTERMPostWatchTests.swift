// SIGTERMPostWatchTests.swift - A failure behind a posted SIGTERM ends as a cancel, whether or not the handler ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A54 M3 (decision P2, SWIFT 3, S30 note 2). The app signals a leaf's whole group at once, so a
// tool that got the same SIGTERM can end the work before the leaf has run its handler. With every core busy the
// kernel woke the handler's thread late, and `bam filter` answered its own SIGTERM with exit 64 and no cancelled
// record (build/lane/m3-sigterm-first.log of the lane). The kernel notes a post at once, so the leaf reads the
// post instead of the handler (`SIGTERMPostWatch`). These tests need no tool and no built CLI.

import Darwin
import Foundation
import XCTest
@testable import LungfishCLI

final class SIGTERMPostWatchTests: XCTestCase {
    /// SIGTERM is ignored while the test runs, so no handler can run and the post is all there is to see.
    func testTheWatchSeesAPostedSIGTERMThoughNoHandlerRuns() {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let watch = SIGTERMPostWatch()
        XCTAssertFalse(watch.occurred, "nothing was posted yet")
        XCTAssertEqual(kill(getpid(), SIGTERM), 0)
        XCTAssertTrue(watch.occurred, "the kernel noted the post")
    }

    func testAFailureThatFollowsAPostedSIGTERMEndsAsACancel() async {
        struct ToolDied: Error {}
        // The post below is aimed at the process, and the kernel hands it to a thread that can take it later than the
        // pool thread that sent it. If that thread takes it after `end()` has given SIGTERM back the default action,
        // the post ends this test process by signal 15, which happens on a busy machine. With SIGTERM ignored around
        // the run, `end()` restores SIG_IGN, and that drops a post that is still pending.
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let ran = await runCancellingOnSIGTERM { () async throws -> Int in
            // The group's SIGTERM reaches the leaf and its tool together, and the tool's death is the first
            // thing the leaf sees.
            XCTAssertEqual(kill(getpid(), SIGTERM), 0)
            throw ToolDied()
        }
        guard case .failure(let error) = ran else { return XCTFail("the work threw, so the run failed") }
        XCTAssertTrue(error is CancellationError, "a failure behind a SIGTERM is the cancel it answers: \(error)")
    }

    func testAFailureWithNoSIGTERMBehindItStaysAFailure() async {
        struct ToolDied: Error {}
        let ran = await runCancellingOnSIGTERM { () async throws -> Int in throw ToolDied() }
        guard case .failure(let error) = ran else { return XCTFail("the work threw, so the run failed") }
        XCTAssertTrue(error is ToolDied, "a failure no signal explains is not turned into a cancel: \(error)")
    }
}
