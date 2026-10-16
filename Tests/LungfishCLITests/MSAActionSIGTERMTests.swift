// MSAActionSIGTERMTests.swift - How a SIGTERM ends an MSA action (Phase 2.11 lane S61, K7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The `msa` actions are synchronous and run no external tool, and Foundation refuses to read a FIFO, so
// neither a stand-in tool nor a blocked read can hold one in flight in a child process. This test runs
// the real action and the real cancel path, `MSAActionCommand.runActionCancellingOnSIGTERM`, in the
// test process. The first event the action emits is a seam that waits for the SIGTERM handler's
// cancel, a second task posts one SIGTERM to the test process once the action is held, and the action
// then reads the alignment with the cancel pending and meets its cancel point.

import ArgumentParser
import Darwin
import Foundation
import Synchronization
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class MSAActionSIGTERMTests: XCTestCase {
    private final class EmittedLines: Sendable {
        private let storage = Mutex<[String]>([])
        func append(_ line: String) { storage.withLock { $0.append(line) } }
        var all: [String] { storage.withLock { $0 } }
    }

    /// A SIGTERM during `msa extract` cancels the run. The command exits 125, records the run as
    /// cancelled beside the output it did not write, and the stream holds one `failed` line.
    func testSIGTERMCancelsAnMSAExtractionHeldInFlightAndRecordsItCancelled() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let output = project.directory.appendingPathComponent("Extracted.fasta")
        let record = URL(fileURLWithPath: output.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)
        let command = try MSACommand.ExtractSubcommand.parse([
            project.msaBundleURL.path, "--output-kind", "fasta", "--output", output.path, "--format", "json",
        ])
        let executor = command.msaExecutor
        let emitted = EmittedLines()
        let held = DispatchSemaphore(value: 0)

        // A SIGTERM that arrives late must not end the test runner.
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }

        @Sendable func awaitHeld() -> Bool { held.wait(timeout: .now() + 30) == .success }
        let poster = Task.detached {
            if awaitHeld() { kill(getpid(), SIGTERM) }
        }
        var thrown: (any Error)?
        do {
            try await command.runActionCancellingOnSIGTERM(emit: { emitted.append($0) }) { _ in
                try executor { line in
                    emitted.append(line)
                    guard emitted.all.count == 1 else { return }
                    held.signal()
                    // Held in flight until the SIGTERM handler cancels this task.
                    let deadline = ContinuousClock.now + .seconds(20)
                    while !Task.isCancelled, ContinuousClock.now < deadline { usleep(10_000) }
                }
            }
        } catch {
            thrown = error
        }
        await poster.value

        XCTAssertEqual(thrown as? ExitCode, CLIExitCode.cancelled.exitCode, "a cancelled action exits 125, ended with \(String(describing: thrown))")
        XCTAssertEqual(try SIGTERMPinSupport.recordStatus(at: record), "cancelled", "the command records its run as cancelled")
        XCTAssertEqual(
            emitted.all.filter { $0.contains(#""event":"failed""#) }.count, 1,
            "the stream holds one failed line: \(emitted.all)"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no output was written")
    }
}
