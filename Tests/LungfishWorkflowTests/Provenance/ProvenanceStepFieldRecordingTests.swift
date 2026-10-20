// ProvenanceStepFieldRecordingTests.swift - The fields schema version 2 added to a step survive every hop
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P8, plan decision S6. A writer that records through `ProvenanceRecorder` builds
// `StepExecution` values, the record keeps `ProvenanceStep` values, and the export plan reads a
// `WorkflowRun` made from the record. The three fields schema version 2 added to a step, `parentStepID`,
// `managedToolID` and `toolVersionEvidence`, cross each of those hops. A writer such as Bracken records
// its evidence through `recordStep`, so a field the recorder cannot take would never reach a record.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ProvenanceStepFieldRecordingTests: XCTestCase {

    private let tool = ManagedToolID(rawValue: "samtools")
    private var evidence: ToolVersionEvidence { .lockPin(version: "1.24", id: tool) }

    private func step(_ name: String, argv: [String], id: UUID = UUID(), parent: UUID? = nil) -> ProvenanceStep {
        ProvenanceStep(
            id: id, toolName: name, toolVersion: "1.24", argv: argv, exitStatus: 0,
            parentStepID: parent, managedToolID: tool, toolVersionEvidence: evidence
        )
    }

    func testTheNewStepFieldsSurviveTheConversionsBetweenARecordAndARun() throws {
        let importID = UUID()
        let record = ProvenanceEnvelope(workflowName: "step field recording test", toolName: "lungfish-cli", steps: [
            step("lungfish import fastq", argv: ["lungfish-cli", "import", "fastq", "/data/a.fastq"], id: importID),
            step("seqkit", argv: ["seqkit", "stats"], parent: importID),
        ])
        let run = record.legacyWorkflowRun(preferCanonicalSteps: true)
        XCTAssertEqual(run.steps.map(\.parentStepID), [nil, importID], "the record to the run")
        XCTAssertEqual(run.steps.map(\.managedToolID), [tool, tool])
        XCTAssertEqual(run.steps.map(\.toolVersionEvidence), [evidence, evidence])

        let back = run.steps.map { ProvenanceStep(stepExecution: $0) }
        XCTAssertEqual(back.map(\.parentStepID), [nil, importID], "the run to the record")
        XCTAssertEqual(back.map(\.managedToolID), [tool, tool])
        XCTAssertEqual(back.map(\.toolVersionEvidence), [evidence, evidence])
    }

    func testTheRecorderRecordsTheNewStepFieldsAndTheSavedRecordKeepsThem() async throws {
        let directory = try makeStepParentDirectory().appendingPathComponent("Recorded.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = ProvenanceRecorder.shared
        let runID = await recorder.beginRun(name: "step field recorder test")
        let importID = await recorder.recordStep(
            runID: runID, toolName: "lungfish import fasta", toolVersion: "1.0",
            command: ["lungfish-cli", "import", "fasta", "/data/a.fa"], inputs: [], outputs: [], exitCode: 0, wallTime: 1
        )
        let childID = await recorder.recordStep(
            runID: runID, toolName: "samtools", toolVersion: "1.24",
            command: ["samtools", "faidx", "a.fa"], inputs: [], outputs: [], exitCode: 0, wallTime: 1,
            parentStepID: importID, managedToolID: tool, toolVersionEvidence: evidence
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(runID: runID, to: directory)

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: directory))
        XCTAssertEqual(record.steps.map(\.id), [try XCTUnwrap(importID), try XCTUnwrap(childID)])
        XCTAssertEqual(record.steps.map(\.parentStepID), [nil, importID])
        XCTAssertEqual(record.steps.map(\.managedToolID), [nil, tool])
        XCTAssertEqual(record.steps.map(\.toolVersionEvidence), [nil, evidence])
    }

    func testAStepExecutionRecordsNoneOfThemUnlessAWriterSetsThem() {
        let step = StepExecution(toolName: "samtools", toolVersion: "1.24", command: ["samtools"], inputs: [])
        XCTAssertNil(step.parentStepID)
        XCTAssertNil(step.managedToolID)
        XCTAssertNil(step.toolVersionEvidence)
        let converted = ProvenanceStep(stepExecution: step)
        XCTAssertNil(converted.parentStepID)
        XCTAssertNil(converted.managedToolID)
        XCTAssertNil(converted.toolVersionEvidence)
    }

    /// The FASTQ importer rebuilds the steps its ingestion recorded to name the published bundle, and
    /// P4 attaches a tool id and version evidence to those steps. The rebuild keeps every field it does
    /// not rewrite, the fields schema version 2 added among them.
    func testTheImporterRehydratesIngestionStepsWithEveryField() throws {
        let sourceOutput = URL(fileURLWithPath: "/Users/tester/ingest/S.fastq.gz")
        let finalOutput = URL(fileURLWithPath: "/Users/tester/Demo.lungfish/Imports/.S.building-6127824B/S.fastq.gz")
        let original = StepExecution(
            id: UUID(), toolName: "clumpify.sh", toolVersion: "40.02", githubReleaseVersion: "v40.02",
            containerImage: "bbtools:40.02", containerDigest: "sha256:abc123",
            command: ["clumpify.sh", "in=/data/a.fastq", "out=\(sourceOutput.path)"],
            durableReplayArgv: ["clumpify.sh", "in=/data/a.fastq", "out=\(sourceOutput.path)"],
            resolvedOptions: ["groups": .string("auto")],
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "bbtools", condaPrefix: "/envs/bbtools"),
            inputs: [FileRecord(path: "/data/a.fastq", role: .input)],
            outputs: [FileRecord(path: sourceOutput.path, role: .output)],
            exitCode: 0, wallTime: 3, peakMemoryBytes: 2_048, stderr: "a warning", dependsOn: [UUID()],
            parentStepID: UUID(), managedToolID: ManagedToolID(rawValue: "bbtools"),
            toolVersionEvidence: .observed(version: "40.02", reportedLine: nil), stdoutReadInProcess: true,
            startTime: Date(timeIntervalSince1970: 1_790_000_000), endTime: Date(timeIntervalSince1970: 1_790_000_003)
        )
        assertEveryPropertyIsSet(in: original)

        let rehydrated = try XCTUnwrap(FASTQBatchImporter.rehydratedIngestionSteps(
            [original], sourceOutputURL: sourceOutput, finalOutputURL: finalOutput, originalInputURLs: []
        ).first)
        // The importer rebuilds the steps of a FASTQ import, which LGE never reads in the app, and the ARCH ruling
        // for 13.16 M2 leaves this site as it is, so it does not carry `stdoutReadInProcess`.
        assertEveryPropertyCarried(
            rehydrated, from: original, except: ["durableReplayArgv", "inputs", "outputs", "stdoutReadInProcess"],
            "FASTQBatchImporter.rehydratedIngestionSteps"
        )
        XCTAssertEqual(rehydrated.outputs.first?.path, finalOutput.path, "and it still names the published bundle")
    }

    /// The conversions between a record's step and the run's step name every field. A field a step gains
    /// without a conversion line defaults to nothing there and a record that goes through the run view loses it,
    /// which is how a parent could have been dropped. This test fails when the step's fields change, so the
    /// conversions in `ProvenanceRecord.swift`, `StepExecution`, `recordStep` and the rebuild sites get a look.
    func testTheStepFieldsTheRunConversionsCarryAreTheStepFieldsThereAre() {
        let fields = Mirror(reflecting: ProvenanceStep(toolName: "samtools")).children.compactMap(\.label)
        XCTAssertEqual(fields, [
            "id", "toolName", "toolVersion", "githubReleaseVersion", "argv", "durableReplayArgv", "reproducibleCommand",
            "resolvedOptions", "runtimeIdentity", "inputs", "outputs", "exitStatus", "wallTimeSeconds", "peakMemoryBytes",
            "stderr", "dependsOn", "startedAt", "completedAt", "parentStepID", "managedToolID", "toolVersionEvidence",
            "observation", "stdoutReadInProcess",
            // A fact of one file's sidecar view of a `build-db esviritu` step, never of the run, so the run
            // conversions do not carry it (2.13 lane 13.15 M2, ARCH Q-A3-SHAPE item 7).
            "narrowedFrom",
        ], "ProvenanceStep gained or lost a field. Carry it through StepExecution, recordStep, ProvenanceStep.init(stepExecution:) and legacyWorkflowRun, then list it here.")
    }

    // MARK: - stdoutReadInProcess (Phase 2.13 lane 13.16, the ARCH ruling for M2)

    /// The mark the `samtools coverage` and `samtools view` passes of a mapping summary carry crosses every
    /// hop the other step fields cross: the typed record, the record's step, the envelope and the run view.
    func testAStepReadInProcessKeepsTheMarkThroughTheRecordAndTheRunView() throws {
        let original = StepExecution(
            toolName: "samtools", toolVersion: "1.24", command: ["samtools", "coverage", "/data/a.bam"], inputs: [],
            exitCode: 0, wallTime: 1, stdoutReadInProcess: true
        )
        XCTAssertEqual(original.stdoutReadInProcess, true)
        let typed = try JSONDecoder().decode(StepExecution.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(typed.stdoutReadInProcess, true, "the typed record's step written and read")

        let converted = ProvenanceStep(stepExecution: typed)
        XCTAssertEqual(converted.stdoutReadInProcess, true, "the conversion to the record's step")
        let record = ProvenanceEnvelope(workflowName: "mark test", toolName: "lungfish-cli", steps: [converted])
        let readBack = try JSONDecoder().decode(ProvenanceEnvelope.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(readBack.steps.map(\.stdoutReadInProcess), [true], "the envelope written and read")

        let run = readBack.legacyWorkflowRun(preferCanonicalSteps: true)
        XCTAssertEqual(run.steps.map(\.stdoutReadInProcess), [true], "the run view")
        let again = ProvenanceStep(stepExecution: try XCTUnwrap(run.steps.first))
        XCTAssertEqual(again.stdoutReadInProcess, true, "and back to the record's step")
    }

    /// A step that was not read in the app writes no key, and a step written without the key reads as nil, so
    /// the record of every other writer and every record written before 2.13 stays as it was.
    func testAStepWithoutTheMarkWritesNoKey() throws {
        let execution = StepExecution(toolName: "samtools", toolVersion: "1.24", command: ["samtools", "faidx", "a.fa"], inputs: [])
        let step = ProvenanceStep(toolName: "samtools")
        let executionData = try JSONEncoder().encode(execution)
        let stepData = try JSONEncoder().encode(step)
        for (label, data) in [("StepExecution", executionData), ("ProvenanceStep", stepData)] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertFalse(object.isEmpty, label)
            XCTAssertNil(object["stdoutReadInProcess"], "\(label) writes no key for a nil mark")
        }
        XCTAssertNil(try JSONDecoder().decode(StepExecution.self, from: executionData).stdoutReadInProcess)
        XCTAssertNil(try JSONDecoder().decode(ProvenanceStep.self, from: stepData).stdoutReadInProcess)
    }
}
