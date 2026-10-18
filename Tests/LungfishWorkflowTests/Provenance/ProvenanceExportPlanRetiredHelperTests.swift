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
//
// The record's two in-app steps (the clone of an already sorted BAM and the collection of alignment metadata)
// are built from that argv and append a marker flag that no command accepts. They stay in-app steps whatever
// executable they name (review of M2, fix 1), so no export replays them as a `lungfish-cli` command.

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class ProvenanceExportPlanRetiredHelperTests: XCTestCase {
    private func plan(commands: [[String]]) -> ProvenanceExportPlan {
        var run = WorkflowRun(name: "bam import", appVersion: "Lungfish 2026.10.20", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = commands.map { command in
            StepExecution(
                toolName: "lungfish bam import",
                toolVersion: "2026.10.20",
                command: command,
                inputs: [],
                outputs: [],
                exitCode: 0,
                wallTime: 1
            )
        }
        return ProvenanceExportPlan(run: run, replayArguments: { $0.durableReplayArgv ?? $0.command })
    }

    func testAnOldRecordOfTheBAMImportHelperIsHistoryAndIsNotReplayed() {
        let plan = plan(commands: [[
            "Lungfish", "--bam-import-helper", "--bam-path", "/p/sample.bam",
            "--bundle-path", "/p/Reference.lungfishref", "--name", "sample.bam",
        ]])
        XCTAssertTrue(plan.replayableSteps.isEmpty, "the helper step is not replayed: \(plan.steps)")
        XCTAssertEqual(plan.inAppSteps.count, 1, "it is named as an in-app step: \(plan.steps)")
        XCTAssertEqual(plan.inAppSteps.first?.recordedArgv.dropFirst().first, "--bam-import-helper", "and keeps its spelling")
    }

    func testANewRecordNamesTheImportBamLeafAndIsReplayed() {
        let plan = plan(commands: [[
            CLICommandIdentity.executableName, "import", "bam", "/p/sample.bam",
            "--output-dir", "/p/Reference.lungfishref", "--name", "sample.bam",
        ]])
        XCTAssertEqual(plan.replayableSteps.count, 1, "\(plan.steps)")
        XCTAssertEqual(plan.replayableSteps.first?.kind, .wrapper, "a lungfish-cli step")
        XCTAssertTrue(plan.inAppSteps.isEmpty)
    }

    /// A new BAM record names `lungfish-cli import bam` in its argv, and the writer builds the record's two in-app
    /// steps from that argv with a marker flag appended, `--clone-sorted-alignment` for the clone of an already sorted
    /// BAM and `--collect-alignment-metadata --metadata-db <path>` for the alignment metadata. No command accepts
    /// either flag, so each is an in-app step and no export replays it, while the samtools steps of the record stay
    /// replayable.
    func testTheInAppMarkerStepsOfAnImportBamRecordAreNotReplayed() {
        let bundle = "/p/Reference.lungfishref"
        let importArgv = [CLICommandIdentity.executableName, "import", "bam", "/p/sample.bam", "--output-dir", bundle]
        let plan = plan(commands: [
            ["samtools", "sort", "-o", "\(bundle)/alignments/a.bam", "/p/sample.bam"],
            ["samtools", "index", "\(bundle)/alignments/a.bam"],
            importArgv + ["--collect-alignment-metadata", "--metadata-db", "\(bundle)/alignments/a.stats.db"],
            importArgv + ["--clone-sorted-alignment"],
        ])
        XCTAssertEqual(plan.replayableSteps.count, 2, "only the samtools steps are replayed: \(plan.steps)")
        XCTAssertEqual(plan.inAppSteps.count, 2, "the two marker steps are named, not replayed: \(plan.steps)")
        let markers: Set<String> = ["--clone-sorted-alignment", "--collect-alignment-metadata"]
        XCTAssertFalse(
            plan.replayableSteps.contains { !markers.isDisjoint(with: $0.recordedArgv) },
            "no replayed step carries a marker flag: \(plan.replayableSteps.map(\.recordedArgv))"
        )
    }
}
