// GenotypeManualHaplotypeTransitionTests+Wait.swift - The bounded wait for the manual haplotype termination run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishTestSupport

/// Backlog row HAPLOTYPE-WAIT-UNBOUNDED, review LOOP-QA B2. The delegate's wait for its termination run ends at a
/// deadline and says whether the run ended, so a run that never ends fails one test with words instead of holding the
/// App bundle until its bound.
@MainActor
extension XCTestCase {
    /// Waits for the delegate's manual haplotype termination run inside the standard budget, and fails with words
    /// when the run does not end. GenotypeManualHaplotypeTransitionTests and ProjectFilesystemWindowOwnershipTests
    /// call it.
    func waitForManualHaplotypeTermination(
        of delegate: AppDelegate, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let ended = await delegate.testingWaitForManualHaplotypeTermination(timeout: WaitBudget.standard.duration)
        XCTAssertTrue(ended, "the manual haplotype termination run did not end inside the "
                      + "\(WaitBudget.standard.name) wait budget", file: file, line: line)
    }
}

extension GenotypeManualHaplotypeTransitionTests {
    func testTheHaplotypeWaitReturnsFalseWhenNoRunEnds() async {
        let controller = MainWindowController()
        let delegate = AppDelegate()
        let (released, release) = AsyncStream<Void>.makeStream()
        controller.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { true },
            prepare: { _ in
                for await _ in released { break }
                return false
            }
        )
        delegate.testingSetMainWindowControllers([controller])
        XCTAssertEqual(delegate.testingApplicationShouldTerminate { _ in }, .terminateLater)

        // The run cannot end while the test holds its prompt, so a short bound gives the same answer as a long one.
        let endedWhileHeld = await delegate.testingWaitForManualHaplotypeTermination(timeout: .milliseconds(200))
        XCTAssertFalse(endedWhileHeld, "the wait said the run ended while the test still held its prompt")

        release.yield()
        release.finish()
        await waitForManualHaplotypeTermination(of: delegate)
    }
}
