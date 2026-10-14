// NextflowWorkflowContractParityReplayTests+Scratch.swift - What today's Viral Recon route leaves of its launch scratch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M2, plan P3 with QA's addition. Before `workflow run` moves onto `NextflowEngineProcess`, these
// cases pin what the route does with its launch scratch, the `nfcore-run-` folder that holds Nextflow's `.nextflow/`
// and `work/`, after a run that completes, one that fails and one that a SIGTERM cancels. P3 keeps a cancelled run's
// scratch for the abandoned-scratch sweep (2.9 N7), so the commit that does it changes the cancel case and no other.

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

extension NextflowWorkflowContractParityReplayTests {
    /// A run that completes removes its launch scratch.
    func testACompletedRunRemovesItsLaunchScratch() throws {
        let run = try runRoute(.docker, case: "scratch-completed")
        XCTAssertEqual(run.status, 0, run.stderr)
        let launch = try XCTUnwrap(run.launches.first, "the route launched nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.workingDirectory), "the scratch \(launch.workingDirectory) is left")
    }

    /// A run whose engine fails removes its launch scratch.
    func testAFailedRunRemovesItsLaunchScratch() throws {
        let run = try runRoute(.docker, case: "scratch-failed", behaviour: .failsSamples(["S1"]))
        XCTAssertNotEqual(run.status, 0, "the stand-in failed the sample")
        let launch = try XCTUnwrap(run.launches.first, "the route launched nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.workingDirectory), "the scratch \(launch.workingDirectory) is left")
    }

    /// A SIGTERM while the engine runs cancels the run. The command exits 125 inside the app's grace with no process
    /// of its tree left. Today's `defer` removes the launch scratch on this exit too, and the manifest still reads
    /// `running`, since the route writes no record for a cancel.
    func testACancelledRunExits125AndRemovesItsLaunchScratch() async throws {
        let caseRoot = root.appendingPathComponent("scratch-cancelled", isDirectory: true)
        let (engine, arguments, environment) = try routeCommand(.docker, caseRoot: caseRoot, behaviour: .waitsUntilCancelled)
        let project = caseRoot.appendingPathComponent("Project", isDirectory: true)
        let cli = try CLISIGTERMHarness.launchCLI(arguments, environment: environment, workingDirectory: project, testClass: Self.self)
        defer { cli.stop() }
        guard let launch = await engine.waitForLaunch() else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The CLI never launched the stand-in.\(stop.diagnostics)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.workingDirectory), "the engine runs in the scratch")
        // The engine streams its log at its final name in the run bundle while it runs (2.9 N8).
        let bundle = project.appendingPathComponent("Analyses/viralrecon.lungfishrun", isDirectory: true)
        let log = bundle.appendingPathComponent("logs/nextflow.log")
        let streaming = await CLISIGTERMHarness.waitForFile(log)
        XCTAssertTrue(streaming && ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("\n--- stdout ---\n"), "the log streams while the engine runs")

        let stop = await CLISIGTERMHarness.cancel(cli)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(stop.standardError.contains("Workflow cancelled"), stop.diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.workingDirectory), "today's defer removes the scratch of a cancelled run")
        XCTAssertTrue(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("\n--- stderr ---\n"), "the log is whole once the tree is gone")
        XCTAssertEqual(try NFCoreRunBundleStore.read(from: bundle).executionStatus, .running, "today's route writes no record for a cancel")
    }
}
