// ProvenanceStepParentRecordingTests.swift - The parent a step records survives every hop to a record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P8, plan decision S6. A writer that records through `ProvenanceRecorder` builds
// `StepExecution` values, the record keeps `ProvenanceStep` values, and the export plan reads a
// `WorkflowRun` made from the record. `parentStepID` crosses each of those hops.

import XCTest
@testable import LungfishWorkflow

final class ProvenanceStepParentRecordingTests: XCTestCase {

    private func step(_ tool: String, argv: [String], id: UUID = UUID(), parent: UUID? = nil) -> ProvenanceStep {
        ProvenanceStep(id: id, toolName: tool, toolVersion: "1.0", argv: argv, exitStatus: 0, parentStepID: parent)
    }

    func testTheParentSurvivesTheConversionsBetweenARecordAndARun() throws {
        let importID = UUID()
        let record = ProvenanceEnvelope(workflowName: "step parent recording test", toolName: "lungfish-cli", steps: [
            step("lungfish import fastq", argv: ["lungfish-cli", "import", "fastq", "/data/a.fastq"], id: importID),
            step("seqkit", argv: ["seqkit", "stats"], parent: importID),
        ])
        let run = record.legacyWorkflowRun(preferCanonicalSteps: true)
        XCTAssertEqual(run.steps.map(\.parentStepID), [nil, importID], "the record to the run")
        let back = run.steps.map { ProvenanceStep(stepExecution: $0) }
        XCTAssertEqual(back.map(\.parentStepID), [nil, importID], "the run to the record")
    }

    func testTheRecorderRecordsTheParentAndTheSavedRecordKeepsIt() async throws {
        let directory = try makeStepParentDirectory().appendingPathComponent("Recorded.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = ProvenanceRecorder.shared
        let runID = await recorder.beginRun(name: "step parent recorder test")
        let importID = await recorder.recordStep(
            runID: runID, toolName: "lungfish import fasta", toolVersion: "1.0",
            command: ["lungfish-cli", "import", "fasta", "/data/a.fa"], inputs: [], outputs: [], exitCode: 0, wallTime: 1
        )
        let childID = await recorder.recordStep(
            runID: runID, toolName: "samtools", toolVersion: "1.24",
            command: ["samtools", "faidx", "a.fa"], inputs: [], outputs: [], exitCode: 0, wallTime: 1,
            parentStepID: importID
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(runID: runID, to: directory)

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: directory))
        XCTAssertEqual(record.steps.map(\.id), [try XCTUnwrap(importID), try XCTUnwrap(childID)])
        XCTAssertEqual(record.steps.map(\.parentStepID), [nil, importID])
    }

    func testAStepExecutionRecordsNoParentUnlessAWriterSetsOne() {
        let step = StepExecution(toolName: "samtools", toolVersion: "1.24", command: ["samtools"], inputs: [])
        XCTAssertNil(step.parentStepID)
        XCTAssertNil(ProvenanceStep(stepExecution: step).parentStepID)
    }
}
