// SIGTERMCancellationTests.swift - SIGTERM cancels the import task instead of ending the process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import LungfishTestSupport
@testable import LungfishCLI

/// Review finding S4-S3: the window stops `lungfish-cli import fastq` with
/// SIGTERM. The CLI died at once and left its staging bundle and workspace.
/// It now turns SIGTERM into a cancel so the import's cleanup runs.
///
/// Re-review finding S6-1: a SIGTERM caught before the dispatch source was
/// registered was lost, so the import was never cancelled.
final class SIGTERMCancellationTests: XCTestCase {

    func testSIGTERMCancelsTheTaskAndTheProcessLivesOn() async throws {
        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        defer { task.cancel() }
        let termination = SIGTERMCancellation(cancelling: task)
        defer { termination.end() }

        // Sent to this test process. Without the handler it would end it.
        kill(getpid(), SIGTERM)

        let cancelled = await waitUntil(timeout: .seconds(5)) { task.isCancelled }
        XCTAssertTrue(cancelled, "SIGTERM cancels the task")
    }

    /// The SIGTERM lands after the handler is in place and before the dispatch
    /// source is listening. kill() to this process delivers it before it
    /// returns, so the timing is fixed.
    func testASIGTERMBeforeTheSourceListensStillCancels() async throws {
        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        defer { task.cancel() }
        let termination = SIGTERMCancellation(beforeListening: { kill(getpid(), SIGTERM) }) {
            task.cancel()
        }
        defer { termination.end() }

        let cancelled = await waitUntil(timeout: .seconds(5)) { task.isCancelled }
        XCTAssertTrue(cancelled, "a SIGTERM caught before the source listens still cancels")
    }

    func testAToolTheCommandLaunchesStillStopsOnSIGTERM() async throws {
        let task = Task<Bool, Never> { false }
        let termination = SIGTERMCancellation(cancelling: task)
        defer { termination.end() }

        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/sleep")
        tool.arguments = ["30"]
        try tool.run()
        defer { if tool.isRunning { kill(tool.processIdentifier, SIGKILL) } }
        tool.terminate()

        let stopped = await waitUntil(timeout: .seconds(10)) { !tool.isRunning }
        XCTAssertTrue(stopped, "a caught SIGTERM goes back to its default action in a launched tool")
        XCTAssertEqual(tool.terminationReason, .uncaughtSignal)
    }
}
