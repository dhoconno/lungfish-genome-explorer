// ViralReconWorkflowProcessRunnerTests.swift - The runner behind the Viral Recon and Local Workflow routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S16 (decision N14, fact ruling F8). The Viral Recon route and the Local Workflow route
// both start `lungfish-cli workflow run` through `ProcessViralReconWorkflowProcessRunner`. These cases run
// the real runner against a shell stand-in for the CLI, so they pin what a user's Cancel does to the
// process and what the runner hands back. Nothing here needs Nextflow or Docker.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class ViralReconWorkflowProcessRunnerTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "viral-recon-process-runner")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - Cancel

    /// A cancel sends the CLI SIGTERM and gives it time to clean up before SIGKILL. The stand-in takes
    /// 0.4 s to write its marker after SIGTERM, as the real CLI takes time to stop Nextflow and record
    /// its run as cancelled. A cancel that follows SIGTERM with SIGKILL at once, as the runner did with
    /// a grace of 0, leaves no marker.
    func testACancelGivesTheCLITimeToCleanUpBeforeItIsKilled() async throws {
        let ready = scratch.appendingPathComponent("ready")
        let marker = scratch.appendingPathComponent("cleaned")
        let cli = try writeCLI(
            """
            trap 'sleep 0.4; echo cleaned > "$2"; exit 125' TERM
            : > "$1"
            sleep 30 &
            wait $!
            """
        )
        let runner = ProcessViralReconWorkflowProcessRunner(executableURL: cli)
        let directory = scratch!
        let run = Task {
            try await runner.runLungfishCLI(
                arguments: [ready.path, marker.path],
                workingDirectory: directory,
                outputHandler: nil
            )
        }

        try await waitForFile(ready)
        let cancelStart = Date()
        runner.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(cancelStart), 2, "cancel() only asks for the stop and never waits")
        let result = try await run.value

        // Known issue (S16, F8). The runner cancels with a grace of 0, so SIGKILL follows SIGTERM at once
        // and the CLI is gone before it writes the marker. The commit that gives the runner its 6 s grace
        // removes this wrapper. Without it this case fails at the base with exit 9 and no marker.
        XCTExpectFailure("A cancel kills the CLI with no grace today") {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: marker.path),
                "the CLI got no time between SIGTERM and SIGKILL to clean up"
            )
            XCTAssertEqual(result.exitCode, 125, "the CLI's own exit code after its cleanup")
        }
    }

    // MARK: - Helpers

    /// A shell script named `lungfish-cli` that runs `body`. Its arguments are the case's `$1`, `$2` and so on.
    private func writeCLI(_ body: String) throws -> URL {
        let url = scratch.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(url.path)")
    }
}
