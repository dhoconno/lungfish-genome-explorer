// TaxTriageCLICancelSignalTests.swift - The TaxTriage CLI route's cancel signals the command first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 U30 walk, finding W2. A cancel of `lungfish-cli taxtriage run` left three exited containers,
// because the transport's SIGTERM reached the `docker ps` of the command's container cleanup. The TaxTriage
// route now sends SIGTERM to the command alone (`ToolProcessSpec.signalsProcessFirst`), so the command stops
// Nextflow and removes the containers itself, as the legacy route's in-app cleanup does. Kraken2 and EsViritu
// keep the termination of the whole tree. The live form is `TaxTriageParityLiveConformanceTests`'s X6 cancel.
// The runner test below runs `CLIClassifierRunner.run` against a stand-in command, so it shows that the runner
// forwards the choice to the transport, which the static pin cannot.

import XCTest
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

final class TaxTriageCLICancelSignalTests: XCTestCase {
    func testOnlyTheTaxTriageRouteSignalsTheCommandFirst() {
        XCTAssertTrue(CLIClassifierRunner.signalsCommandFirst(.taxTriage))
        XCTAssertFalse(CLIClassifierRunner.signalsCommandFirst(.kraken2))
        XCTAssertFalse(CLIClassifierRunner.signalsCommandFirst(.esViritu))
    }

    /// The grace the command gets covers Nextflow's own grace and the container cleanup's bound.
    func testTheGraceCoversTheEngineStopAndTheContainerCleanup() {
        let engineStopAndCleanup = NextflowEngineProcess.terminationGracePeriod + NextflowEngineProcess.containerCleanupBound
        XCTAssertGreaterThan(CLIClassifierRunner.terminationGracePeriod, engineStopAndCleanup, "the command's cancel must end inside the grace the app gives it")
    }

    /// The runner passes `signalsCommandFirst(_:)` to the transport. The stand-in command starts a two-second cleanup
    /// tool on SIGTERM, as `taxtriage run` starts `docker`, and records it only when that tool ends by itself. On
    /// the TaxTriage route the tool gets no signal, so the marker appears. On the Kraken2 route the SIGTERM to every
    /// descendant stops the tool (exit 143) and the marker does not appear.
    func testTheRunnerLetsTheTaxTriageCommandsCleanupToolRunAndKraken2sNot() async throws {
        for (tool, cleanupRuns) in [(CLIClassifierTool.taxTriage, true), (.kraken2, false)] {
            let root = try TestTempDirectory.make(prefix: "cli-classifier-cancel-signal")
            defer { TestTempDirectory.cleanup(root) }
            let ready = root.appendingPathComponent("ready")
            let cleaned = root.appendingPathComponent("cleaned")
            let cli = try makeStandInCLI(in: root, ready: ready, cleaned: cleaned)
            let runner = CLIClassifierRunner(cliURLOverride: cli)
            let run = Task {
                try await runner.run(CLIClassifierRunRequest(tool: tool, arguments: ["run"], sampleIDs: ["S1"]), operationID: UUID())
            }
            let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(25)) {
                FileManager.default.fileExists(atPath: ready.path)
            }
            XCTAssertTrue(started, "the stand-in command never started")
            runner.cancel()
            _ = await run.result
            XCTAssertEqual(FileManager.default.fileExists(atPath: cleaned.path), cleanupRuns, "\(tool)")
        }
    }

    /// An executable `/bin/sh` script in `root` that touches `ready` once its SIGTERM trap is set, then idles. The trap
    /// runs a two-second `sleep` and touches `cleaned` only if that `sleep` ends without a signal, then exits 125.
    private func makeStandInCLI(in root: URL, ready: URL, cleaned: URL) throws -> URL {
        let url = root.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        trap '/bin/sleep 2 && /usr/bin/touch "\(cleaned.path)"; exit 125' TERM
        /usr/bin/touch "\(ready.path)"
        while :; do /bin/sleep 0.05; done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
