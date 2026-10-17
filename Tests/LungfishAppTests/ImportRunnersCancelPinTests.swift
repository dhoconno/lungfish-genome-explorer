// ImportRunnersCancelPinTests.swift - Pins what a cancel through the two import runners does at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1, decision S7. `CLIApplicationExportImportRunner` and `CLINativeBundleImportRunner`
// build a `CLISubprocessTransport` and pass no `operationGrace` and no `operationDrain`, so a cancel gives
// the command no time between SIGTERM and SIGKILL. A stand-in lungfish-cli that records its cancel one
// second after SIGTERM and exits 125, as a converted command does, is killed before it records anything.
// The S7 commit of this lane flips both cases: the stand-in records its cancel inside the grace.

import Darwin
import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishApp

final class ImportRunnersCancelPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-runners-cancel-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A stand-in `lungfish-cli` that writes its process ID, then on SIGTERM waits one second, writes
    /// its marker and exits 125, which is what a command that records its cancelled run does.
    private func makeStandInCLI() throws -> (cli: URL, started: URL, marker: URL) {
        let cli = root.appendingPathComponent("lungfish-cli")
        let started = root.appendingPathComponent("stand-in.pid")
        let marker = root.appendingPathComponent("cancel-recorded")
        try """
        #!/bin/sh
        echo $$ > '\(started.path)'
        trap 'sleep 1; echo cancelled > '"'"'\(marker.path)'"'"'; exit 125' TERM
        while true; do sleep 1; done
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli, started, marker)
    }

    func testApplicationExportRunnerGivesTheCommandNoTimeToRecordItsCancel() async throws {
        let standIn = try makeStandInCLI()
        let runner = CLIApplicationExportImportRunner(cliURLOverride: standIn.cli)
        let task = Task { try await runner.run(arguments: [], operationID: UUID()) }

        guard let pid = await CLISIGTERMHarness.waitForProcessID(in: standIn.started) else {
            runner.cancel()
            return XCTFail("The stand-in CLI never started.")
        }
        addTeardownBlock { kill(pid, SIGKILL) }
        runner.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run throws CancellationError")
        } catch is CancellationError {
            // expected
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: standIn.marker.path),
            "the runner passes no operationGrace, so SIGKILL follows SIGTERM at once and the command records nothing"
        )
        await CLISIGTERMHarness.assertNoProcessLeft([pid])
    }

    func testNativeBundleRunnerGivesTheCommandNoTimeToRecordItsCancel() async throws {
        let standIn = try makeStandInCLI()
        let runner = CLINativeBundleImportRunner(cliURLOverride: standIn.cli)
        let task = Task { try await runner.run(arguments: [], operationID: UUID()) }

        guard let pid = await CLISIGTERMHarness.waitForProcessID(in: standIn.started) else {
            runner.cancel()
            return XCTFail("The stand-in CLI never started.")
        }
        addTeardownBlock { kill(pid, SIGKILL) }
        runner.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run throws CancellationError")
        } catch is CancellationError {
            // expected
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: standIn.marker.path),
            "the runner passes no operationGrace, so SIGKILL follows SIGTERM at once and the command records nothing"
        )
        await CLISIGTERMHarness.assertNoProcessLeft([pid])
    }
}
