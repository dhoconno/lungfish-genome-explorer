// IlluminaAmpliconPairMergerProcessWaitTests.swift - Waiting for bbmerge to exit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reported 2026-09-03: a 30-sample MiSeq cohort stalled on its fifth sample.
// bbmerge had exited in under a second with a complete merged FASTQ, but the
// CLI stayed asleep in Process.waitUntilExit() with no child process for the
// rest of the session, and the Operations panel offered no way to cancel it.
// The wait now goes through terminationHandler, which Foundation invokes
// exactly once, so a fast-exiting child cannot be missed.

import XCTest
@testable import LungfishWorkflow

final class IlluminaAmpliconPairMergerProcessWaitTests: XCTestCase {

    private func makeStderrURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("merger-wait-\(UUID().uuidString).log")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// bbmerge on an amplicon sample finishes in about a second, and the hang
    /// was intermittent across samples, so the wait is driven many times with
    /// children that exit as fast as a child can. Any missed exit hangs the
    /// test rather than passing it.
    func testWaitReturnsForEveryFastExitingChild() async throws {
        for iteration in 0..<40 {
            let stderrURL = makeStderrURL()
            let result = try await IlluminaAmpliconPairMerger.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo run \(iteration) >&2"],
                stderrURL: stderrURL
            )
            XCTAssertEqual(result.status, 0, "iteration \(iteration)")
            XCTAssertEqual(result.stderr, "run \(iteration)\n", "iteration \(iteration)")
        }
    }

    func testWaitReportsTheChildsExitStatusAndCapturedStderr() async throws {
        let stderrURL = makeStderrURL()
        let result = try await IlluminaAmpliconPairMerger.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo Pairs: 10 >&2; exit 3"],
            stderrURL: stderrURL
        )
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stderr, "Pairs: 10\n")
        XCTAssertEqual(try String(contentsOf: stderrURL, encoding: .utf8), "Pairs: 10\n",
                       "the stderr log stays on disk for triage")
    }

    func testMissingExecutableThrowsInsteadOfHanging() async {
        let stderrURL = makeStderrURL()
        do {
            _ = try await IlluminaAmpliconPairMerger.runProcess(
                executableURL: URL(fileURLWithPath: "/nonexistent/bbmerge.sh"),
                arguments: [],
                stderrURL: stderrURL
            )
            XCTFail("expected launch failure")
        } catch {
            // Foundation reports the launch failure; the wait is never entered.
        }
    }
}
