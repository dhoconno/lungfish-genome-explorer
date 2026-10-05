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
final class SIGTERMCancellationTests: XCTestCase {

    func testSIGTERMCancelsTheTaskAndTheProcessLivesOn() async throws {
        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(60))
            return Task.isCancelled
        }
        let termination = SIGTERMCancellation(cancelling: task)
        defer { termination.end() }

        // Sent to this test process. Without the handler it would end it.
        kill(getpid(), SIGTERM)

        let cancelled = await task.value
        XCTAssertTrue(cancelled, "SIGTERM cancels the task")
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
