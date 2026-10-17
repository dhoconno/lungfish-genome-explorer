// ImportRunnersCancelTests.swift - A cancel through the two import runners gives the command the grace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1, decision S7. `CLIApplicationExportImportRunner` and `CLINativeBundleImportRunner`
// pass `operationGrace` and `operationDrain` to their transport, so a cancel gives the command six seconds
// between SIGTERM and SIGKILL. A stand-in lungfish-cli that records its cancel one second after SIGTERM and
// exits 125, as a converted command does, records it, and the runner throws `CancellationError`. At the base
// (`ImportRunnersCancelPinTests`, commit 7e6fad694) the same stand-in was killed first and recorded nothing.
// A command that exits 125 on its own reads as cancelled too.

import Darwin
import Foundation
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp

final class ImportRunnersCancelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-runners-cancel")
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

    private func makeExit125CLI() throws -> URL {
        let cli = root.appendingPathComponent("lungfish-cli-exit-125")
        try "#!/bin/sh\nexit 125\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli
    }

    /// Cancels the run once the stand-in is up, and returns how long the cancel took to end it.
    private func cancelRun(
        standIn: (cli: URL, started: URL, marker: URL),
        cancel: @escaping @Sendable () -> Void,
        run: @escaping @Sendable () async throws -> Void
    ) async throws -> Duration {
        let task = Task { try await run() }
        guard let pid = await CLISIGTERMHarness.waitForProcessID(in: standIn.started) else {
            cancel()
            XCTFail("The stand-in CLI never started.")
            return .zero
        }
        addTeardownBlock { kill(pid, SIGKILL) }
        let cancelledAt = ContinuousClock.now
        cancel()
        do {
            try await task.value
            XCTFail("A cancelled run throws CancellationError")
        } catch is CancellationError {
            // expected
        }
        let elapsed = ContinuousClock.now - cancelledAt
        await CLISIGTERMHarness.assertNoProcessLeft([pid])
        return elapsed
    }

    func testApplicationExportRunnerLetsTheCommandRecordItsCancelInsideTheGrace() async throws {
        let standIn = try makeStandInCLI()
        let runner = CLIApplicationExportImportRunner(cliURLOverride: standIn.cli)
        let elapsed = try await cancelRun(
            standIn: standIn,
            cancel: { runner.cancel() },
            run: { _ = try await runner.run(arguments: [], operationID: UUID()) }
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: standIn.marker.path),
            "the runner passes operationGrace, so the command records its cancel before SIGKILL"
        )
        XCTAssertLessThan(elapsed, CLIProcessLauncher.operationGrace, "and it does so inside the grace")
    }

    func testNativeBundleRunnerLetsTheCommandRecordItsCancelInsideTheGrace() async throws {
        let standIn = try makeStandInCLI()
        let runner = CLINativeBundleImportRunner(cliURLOverride: standIn.cli)
        let elapsed = try await cancelRun(
            standIn: standIn,
            cancel: { runner.cancel() },
            run: { _ = try await runner.run(arguments: [], operationID: UUID()) }
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: standIn.marker.path),
            "the runner passes operationGrace, so the command records its cancel before SIGKILL"
        )
        XCTAssertLessThan(elapsed, CLIProcessLauncher.operationGrace, "and it does so inside the grace")
    }

    func testBothRunnersPassTheLaunchersGraceAndDrain() {
        XCTAssertEqual(CLIApplicationExportImportRunner.terminationGracePeriod, CLIProcessLauncher.operationGrace)
        XCTAssertEqual(CLIApplicationExportImportRunner.drainGracePeriod, CLIProcessLauncher.operationDrain)
        XCTAssertEqual(CLINativeBundleImportRunner.terminationGracePeriod, CLIProcessLauncher.operationGrace)
        XCTAssertEqual(CLINativeBundleImportRunner.drainGracePeriod, CLIProcessLauncher.operationDrain)
        XCTAssertEqual(CLIProcessLauncher.operationGrace, .seconds(6))
        XCTAssertEqual(CLIProcessLauncher.operationDrain, .milliseconds(500))
    }

    func testAnExitOf125ReadsAsCancelledInBothRunners() async throws {
        let cli = try makeExit125CLI()
        do {
            _ = try await CLIApplicationExportImportRunner(cliURLOverride: cli).run(arguments: [], operationID: UUID())
            XCTFail("A command that exits 125 reads as cancelled")
        } catch is CancellationError {
            // expected
        }
        do {
            _ = try await CLINativeBundleImportRunner(cliURLOverride: cli).run(arguments: [], operationID: UUID())
            XCTFail("A command that exits 125 reads as cancelled")
        } catch is CancellationError {
            // expected
        }
    }
}
