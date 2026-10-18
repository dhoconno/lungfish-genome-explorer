// ProvenanceExportPlanRetiredHelperTests.swift - A record of the retired BAM import helper is history
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.06 (A63-M3 M2, BIO 4). Before 2.12 the in-process BAM imports recorded the app's helper
// re-launch, `<app executable> --bam-import-helper --bam-path <bam> --bundle-path <bundle> --name <name>`, and
// the lane retires that flag. BIO's position is that such a record keeps its spelling as history and is never
// rewritten, and that a new record names a runnable `lungfish-cli import bam`. So the export plan, which the
// shell, Python, Nextflow and Snakemake exports and the workflow graph read, keeps the old step as an in-app
// step that it names and does not replay, and replays the new one as a `lungfish-cli` step.

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class ProvenanceExportPlanRetiredHelperTests: XCTestCase {
    private func plan(command: [String]) -> ProvenanceExportPlan {
        var run = WorkflowRun(name: "bam import", appVersion: "Lungfish 2026.10.20", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = [StepExecution(
            toolName: "lungfish bam import",
            toolVersion: "2026.10.20",
            command: command,
            inputs: [],
            outputs: [],
            exitCode: 0,
            wallTime: 1
        )]
        return ProvenanceExportPlan(run: run, replayArguments: { $0.durableReplayArgv ?? $0.command })
    }

    func testAnOldRecordOfTheBAMImportHelperIsHistoryAndIsNotReplayed() {
        let plan = plan(command: [
            "Lungfish", "--bam-import-helper", "--bam-path", "/p/sample.bam",
            "--bundle-path", "/p/Reference.lungfishref", "--name", "sample.bam",
        ])
        XCTAssertTrue(plan.replayableSteps.isEmpty, "the helper step is not replayed: \(plan.steps)")
        XCTAssertEqual(plan.inAppSteps.count, 1, "it is named as an in-app step: \(plan.steps)")
        XCTAssertEqual(plan.inAppSteps.first?.recordedArgv.dropFirst().first, "--bam-import-helper", "and keeps its spelling")
    }

    func testANewRecordNamesTheImportBamLeafAndIsReplayed() {
        let plan = plan(command: [
            CLICommandIdentity.executableName, "import", "bam", "/p/sample.bam",
            "--output-dir", "/p/Reference.lungfishref", "--name", "sample.bam",
        ])
        XCTAssertEqual(plan.replayableSteps.count, 1, "\(plan.steps)")
        XCTAssertEqual(plan.replayableSteps.first?.kind, .wrapper, "a lungfish-cli step")
        XCTAssertTrue(plan.inAppSteps.isEmpty)
    }
}
