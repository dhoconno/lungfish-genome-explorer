// ProvenanceExportNoOutputStepTests.swift - A tool step LGE read in the app is named, not run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// Decision V1-4 (a) and item 7 of Phase 2.13 lane 13.16, in the plan's test class, as the ARCH ruling for M2
/// narrowed it to a tool step that holds `stdoutReadInProcess` and lists no output file.
extension ProvenanceExportPlanSpecTests {
    func testAToolStepWithNoOutputIsACommentAndNotRun() {
        let run = noOutputFixtureRun([
            noOutputFixtureStep("bcftools", "1.21", ["bcftools", "view", "-o", "/data/out.vcf", "/data/in.vcf"], output: "/data/out.vcf"),
            noOutputFixtureStep("seqkit", "2.8.2", ["seqkit", "stats", "/data/in.fastq"], output: nil, readInProcess: true),
        ])
        let plan = ProvenanceExportPlan(run: run, replayArguments: { $0.durableReplayArgv ?? $0.command }, lock: .bundled)
        XCTAssertEqual(plan.replayableSteps.map(\.toolName), ["bcftools"])
        XCTAssertEqual(plan.steps.map(\.toolName), ["bcftools", "seqkit"])

        let exporter = ProvenanceExporter(signingProvider: nil)
        let shell = exporter.exportShell(run)
        let note = shell.split(separator: "\n").first { $0.hasPrefix("# Step 2 (seqkit") }
        XCTAssertNotNil(note, shell)
        XCTAssertTrue(note?.contains("2.8.2") == true, shell)
        XCTAssertTrue(note?.contains("seqkit stats /data/in.fastq") == true, shell)
        XCTAssertTrue(commandLines(shell).allSatisfy { !$0.contains("seqkit") }, shell)
        XCTAssertTrue(commandLines(shell).contains { $0.contains("bcftools view") }, shell)

        let methods = exporter.exportMethods(run)
        XCTAssertTrue(methods.contains("bcftools"), methods)
        XCTAssertTrue(methods.contains("seqkit"), methods)
    }

    /// The rule reads the mark and an empty `outputs`, so an older record's tool step that listed no output,
    /// and so never held the mark, is run as it always was.
    func testAToolStepWithNoOutputThatLGEDidNotReadIsStillRun() {
        let run = noOutputFixtureRun([
            noOutputFixtureStep("samtools", "1.21", ["samtools", "flagstat", "/data/in.bam"], output: nil),
        ])
        let plan = ProvenanceExportPlan(run: run, replayArguments: { $0.durableReplayArgv ?? $0.command }, lock: .bundled)
        XCTAssertEqual(plan.replayableSteps.map(\.toolName), ["samtools"])
        XCTAssertTrue(plan.noOutputSteps.isEmpty)
        let shell = ProvenanceExporter(signingProvider: nil).exportShell(run)
        XCTAssertTrue(commandLines(shell).contains { $0.contains("flagstat") }, shell)
    }

    func testTheExportedScriptPrintsNoAlignmentStream() {
        let bam = "/project/Analyses/mapping/sorted.bam"
        let run = noOutputFixtureRun([
            noOutputFixtureStep("samtools", "1.21", ["samtools", "sort", "-o", bam, "/project/raw.bam"], output: bam),
            noOutputFixtureStep(
                "samtools", "1.21", ["samtools", "coverage", "--ff", "UNMAP,SECONDARY,QCFAIL,DUP,SUPPLEMENTARY", bam],
                output: nil, readInProcess: true
            ),
            noOutputFixtureStep("samtools", "1.21", ["samtools", "view", bam], output: nil, readInProcess: true),
        ])
        let exporter = ProvenanceExporter(signingProvider: nil)
        let scripts = [("shell", exporter.exportShell(run)), ("python", exporter.exportPython(run))]
        for (format, script) in scripts {
            XCTAssertFalse(commandLines(script).contains { $0.contains("samtools view") || $0.contains("\"view\"") }, "\(format): \(script)")
            // The comment spells the BAM the way the plan maps a result, so it names the file and not the recorded path.
            let note = script.split(separator: "\n").first { $0.hasPrefix("#") && $0.contains("samtools view") }
            XCTAssertNotNil(note, "\(format) names the view pass in a comment: \(script)")
            XCTAssertTrue(note?.contains("sorted.bam") == true, "\(format): \(script)")
            XCTAssertTrue(note?.contains("wrote no file, since LGE read its output in the app") == true, "\(format): \(script)")
        }
        XCTAssertTrue(scripts[0].1.contains("It ran samtools view results/sorted.bam"), scripts[0].1)
    }

    // MARK: - Fixtures

    private func noOutputFixtureRun(_ steps: [StepExecution]) -> WorkflowRun {
        var run = WorkflowRun(name: "no output test", appVersion: "lungfish-cli 2026.10.21", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = steps
        return run
    }

    private func noOutputFixtureStep(
        _ tool: String, _ version: String, _ argv: [String], output: String?, readInProcess: Bool = false
    ) -> StepExecution {
        StepExecution(
            toolName: tool,
            toolVersion: version,
            command: argv,
            inputs: [],
            outputs: output.map { [ProvenanceRecorder.fileRecord(url: URL(fileURLWithPath: $0), role: .output)] } ?? [],
            exitCode: 0,
            wallTime: 1,
            stdoutReadInProcess: readInProcess ? true : nil
        )
    }

    /// The lines of a script that are not comments.
    private func commandLines(_ script: String) -> [Substring] {
        script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }
}
