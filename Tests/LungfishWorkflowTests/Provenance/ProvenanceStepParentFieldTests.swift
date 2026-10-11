// ProvenanceStepParentFieldTests.swift - A step that records the step it ran under
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P8, plan decision S6. A record written from Phase 2.6 on names, in `parentStepID`,
// the CLI step each of its sub-steps ran under. The export plan skips a step whose parent is a CLI
// step of the record and reads a step with no parent, or one whose parent the record does not hold,
// by the staging folder it was recorded in. These tests build the steps as a record holds them and
// read them through the run the exporter makes of the record.

import XCTest
@testable import LungfishWorkflow

final class ProvenanceStepParentFieldTests: XCTestCase {

    private let project = StepParentSupport.project

    // MARK: - A record that names the step each step ran under

    private func recordedStep(
        _ tool: String,
        argv: [String],
        id: UUID = UUID(),
        parent: UUID? = nil,
        outputs: [String] = []
    ) -> ProvenanceStep {
        ProvenanceStep(
            id: id, toolName: tool, toolVersion: "1.0", argv: argv, durableReplayArgv: argv,
            outputs: outputs.map { ProvenanceFileDescriptor(path: $0, role: .output) },
            exitStatus: 0, parentStepID: parent
        )
    }

    /// The run an export reads for a record that holds `steps`.
    private func runOfRecord(_ steps: [ProvenanceStep]) -> WorkflowRun {
        ProvenanceEnvelope(workflowName: "step parent test", toolName: "lungfish-cli", steps: steps)
            .legacyWorkflowRun(preferCanonicalSteps: true)
    }

    private func replayedTools(_ steps: [ProvenanceStep]) -> [String] {
        ProvenanceExportPlan(run: runOfRecord(steps), replayArguments: { $0.durableReplayArgv ?? $0.command })
            .replayableSteps.map(\.toolName)
    }

    private var importArgv: [String] { ["lungfish-cli", "import", "fastq", "/data/a.fastq", "--project", project] }
    private var bundleReads: String { "\(project)/Imports/a.lungfishfastq/a.fastq.gz" }

    func testAStepThatRecordsAParentIsSkippedWithNoStagingFolderToReadIt() {
        let importID = UUID()
        let steps = [
            recordedStep("lungfish import fastq", argv: importArgv, id: importID, outputs: [bundleReads]),
            recordedStep("clumpify.sh", argv: ["clumpify.sh", "in=/data/a.fastq", "out=\(bundleReads)"], parent: importID, outputs: [bundleReads]),
        ]
        XCTAssertEqual(replayedTools(steps), ["lungfish import fastq"])
    }

    func testTheSameStepWithNoParentStaysBecauseNothingReadsIt() {
        let steps = [
            recordedStep("lungfish import fastq", argv: importArgv, outputs: [bundleReads]),
            recordedStep("clumpify.sh", argv: ["clumpify.sh", "in=/data/a.fastq", "out=\(bundleReads)"], outputs: [bundleReads]),
        ]
        XCTAssertEqual(replayedTools(steps), ["lungfish import fastq", "clumpify.sh"])
    }

    func testAParentThatIsNotACLIStepKeepsTheStep() {
        let toolID = UUID()
        let steps = [
            recordedStep("bwa-mem2", argv: ["bwa-mem2", "mem", "ref.fa", "r.fq"], id: toolID),
            recordedStep("samtools", argv: ["samtools", "sort", "in.bam"], parent: toolID),
        ]
        XCTAssertEqual(replayedTools(steps), ["bwa-mem2", "samtools"])
    }

    func testAParentTheRecordDoesNotHoldFallsBackToTheStagingFolder() {
        let missing = UUID()
        let hidden = "\(project)/Imports/.a.building-6127824B-F8D3-415B-BECB-69EB777D0EA7/a.fastq.gz"
        let inStagingFolder = [
            recordedStep("lungfish import fastq", argv: importArgv, outputs: [bundleReads]),
            recordedStep("seqkit", argv: ["seqkit", "stats", hidden], parent: missing, outputs: [bundleReads]),
        ]
        XCTAssertEqual(replayedTools(inStagingFolder), ["lungfish import fastq"], "a command took the steps over, so the folder reads them")
        let elsewhere = [
            recordedStep("lungfish import fastq", argv: importArgv, outputs: [bundleReads]),
            recordedStep("seqkit", argv: ["seqkit", "stats", bundleReads], parent: missing, outputs: [bundleReads]),
        ]
        XCTAssertEqual(replayedTools(elsewhere), ["lungfish import fastq", "seqkit"], "nothing says it ran inside the import")
    }

    func testAParentTheRecordHoldsDecidesEvenInAStagingFolder() {
        let toolID = UUID()
        let hidden = "\(project)/Imports/.a.building-6127824B-F8D3-415B-BECB-69EB777D0EA7/a.fastq.gz"
        let steps = [
            recordedStep("lungfish import fastq", argv: importArgv, outputs: [bundleReads]),
            recordedStep("bgzip", argv: ["bgzip", "x.fa"], id: toolID),
            recordedStep("seqkit", argv: ["seqkit", "stats", hidden], parent: toolID, outputs: [bundleReads]),
        ]
        XCTAssertEqual(replayedTools(steps), ["lungfish import fastq", "bgzip", "seqkit"])
    }

    func testANestedCLIStepKeepsItsSubStepsUnderTheOutermostStep() throws {
        let outerID = UUID()
        let innerID = UUID()
        let steps = [
            recordedStep("lungfish run", argv: ["lungfish-cli", "run", "workflow"], id: outerID),
            recordedStep("lungfish import fastq", argv: importArgv, id: innerID, parent: outerID),
            recordedStep("clumpify.sh", argv: ["clumpify.sh", "in=/data/a.fastq"], parent: innerID),
        ]
        XCTAssertEqual(replayedTools(steps), ["lungfish run"])
        let plan = ProvenanceExportPlan(run: runOfRecord(steps), replayArguments: { $0.durableReplayArgv ?? $0.command })
        let outer = try XCTUnwrap(plan.replayableSteps.first)
        XCTAssertEqual(plan.subSteps(of: outer).map(\.toolName), ["lungfish import fastq", "clumpify.sh"])
        let notes = ProvenanceExporter(signingProvider: nil).exportShell(runOfRecord(steps))
            .split(separator: "\n").filter { $0.contains("ran inside step 1") }
        XCTAssertEqual(notes.count, 2, "the notes sit under the one step the script prints")
    }

    func testAChainOfParentsThatLoopsKeepsEveryStep() {
        let firstID = UUID()
        let secondID = UUID()
        let steps = [
            recordedStep("lungfish first", argv: ["lungfish-cli", "first"], id: firstID, parent: secondID),
            recordedStep("lungfish second", argv: ["lungfish-cli", "second"], id: secondID, parent: firstID),
        ]
        XCTAssertEqual(replayedTools(steps), ["lungfish first", "lungfish second"])
    }
}
