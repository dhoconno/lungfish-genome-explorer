// ProvenanceEnvelopeLineageFocusTests.swift - The record of one file among the many a run wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling Q-S2 of the pre-2.12 session (lane P4). `focusedOnLineage(of:)` keeps the steps that wrote a file,
// the steps without outputs that read it or a path it came from, and the steps that name no file, and drops
// every other step, where `focusedOnOutput` keeps every step without outputs. The records name files that
// are never opened, since the projection reads nothing from the disk.

import XCTest
@testable import LungfishWorkflow

final class ProvenanceEnvelopeLineageFocusTests: XCTestCase {
    /// A probe, a count and the replacement of old bytes that name only the other sample's BAM go, where
    /// `focusedOnOutput`, unchanged for its callers, keeps every step without outputs.
    func testStepsWithoutOutputsThatReadOtherFilesAreDropped() {
        let a = Self.file("/results/A/bams/A.bam", "a2", role: .output)
        let b = Self.file("/results/B/bams/B.bam", "b2", role: .output)
        let record = Self.record([
            Self.step("probe A", inputs: [a.withRole(.input)]),
            Self.step("probe B", inputs: [b.withRole(.input)]),
            Self.step("count B", inputs: [b.withRole(.input)]),
            Self.step("replacement of B", inputs: [Self.file(b.path, "b1")]),
            Self.step("run", outputs: [a, b]),
        ])

        XCTAssertEqual(Self.names(record.focusedOnLineage(of: a)), ["probe A", "run"])
        XCTAssertEqual(Self.names(record.focusedOnOutput(a)), ["probe A", "probe B", "count B", "replacement of B", "run"])
    }

    /// A step without outputs stays when its inputs name the file with any digest, as a probe, a count and the
    /// replacement of its old bytes do, or a path it came from, as a check before the move and the removal of
    /// the `_temp` folders do. The move names that origin, and the run names the file without one, as
    /// `build-db esviritu` does.
    func testStepsThatReadTheFileOrItsOriginAreKept() {
        let tempA = Self.file("/results/A/A_temp/A.bam", "a1")
        let tempB = Self.file("/results/B/B_temp/B.bam", "b1")
        let a = Self.file("/results/A/bams/A.bam", "a2", role: .output)
        let b = Self.file("/results/B/bams/B.bam", "b2", role: .output)
        let record = Self.record([
            Self.step("check of A before the move", inputs: [tempA]),
            Self.step("move", inputs: [tempA, tempB], outputs: [
                Self.file(a.path, "a1", role: .output, origin: tempA.path),
                Self.file(b.path, "b1", role: .output, origin: tempB.path),
            ]),
            Self.step("probe A", inputs: [Self.file(a.path, "a1")]),
            Self.step("replacement of A", inputs: [Self.file(a.path, "a1")]),
            Self.step("count A", inputs: [a.withRole(.input)]),
            Self.step("removal of the _temp folders", inputs: [tempA, tempB]),
            Self.step("removal of B's _temp folder", inputs: [tempB]),
            Self.step("run", inputs: [tempA, tempB], outputs: [a, b]),
        ])

        XCTAssertEqual(Self.names(record.focusedOnLineage(of: a)), [
            "check of A before the move", "move", "probe A", "replacement of A", "count A", "removal of the _temp folders", "run",
        ])
    }

    /// A step that writes the file keeps only that output, as the run names it, as in `focusedOnOutput`. A step
    /// that writes only other files goes even when it read the file, as the index of a BAM does in the BAM's
    /// record. A step that names no file stays in every record, since nothing ties it to one file.
    func testAStepThatWritesTheFileIsNarrowedToItAndAStepThatNamesNoFileStays() {
        let a = Self.file("/results/A/bams/A.bam", "a2", role: .output)
        let index = Self.file("/results/A/bams/A.bam.bai", "i2", role: .index)
        let metrics = Self.file("/results/A/bams/A.markdup.txt", "t", role: .output)
        let record = Self.record([
            Self.step("fixmate"),
            Self.step("markdup", outputs: [Self.file(a.path, "a0", role: .output), metrics]),
            Self.step("index", inputs: [a.withRole(.input)], outputs: [index]),
            Self.step("run", outputs: [a, index, metrics]),
        ])

        let bam = record.focusedOnLineage(of: a)
        XCTAssertEqual(Self.names(bam), ["fixmate", "markdup", "run"])
        XCTAssertEqual(bam.steps.map(\.outputs), [[], [a], [a]])
        let indexRecord = record.focusedOnLineage(of: index)
        XCTAssertEqual(Self.names(indexRecord), ["fixmate", "index", "run"])
        XCTAssertEqual(indexRecord.steps.map(\.outputs), [[], [index], [index]])
    }

    /// A kept step keeps every input, since a step read what it read. The record's files are the inputs of the
    /// kept steps and the file itself, its one output, and the run's other facts stay.
    func testAKeptStepKeepsItsInputsWholeAndTheFilesFollowTheKeptSteps() {
        let tableA = Self.file("/results/A/A.detected_virus.info.tsv", "ta")
        let tableB = Self.file("/results/B/B.detected_virus.info.tsv", "tb")
        let a = Self.file("/results/A/bams/A.bam", "a2", role: .output)
        let b = Self.file("/results/B/bams/B.bam", "b2", role: .output)
        let readB = b.withRole(.input)
        let record = Self.record(
            [Self.step("count B", inputs: [readB]), Self.step("run", inputs: [tableA, tableB], outputs: [a, b])],
            files: [tableA, tableB, readB, a, b]
        )

        let focused = record.focusedOnLineage(of: a)
        XCTAssertEqual(focused.steps.map(\.inputs), [[tableA, tableB]])
        XCTAssertEqual(focused.files, [tableA, tableB, a])
        XCTAssertEqual(record.focusedOnOutput(a).files, [tableA, tableB, readB, a], "today's projection keeps the file count B read")
        XCTAssertEqual(focused.output, a)
        XCTAssertEqual(focused.outputs, [a])
        XCTAssertEqual(focused.id, record.id)
        XCTAssertEqual(focused.workflowName, record.workflowName)
        XCTAssertEqual(focused.argv, record.argv)
        XCTAssertEqual(focused.options, record.options)
        XCTAssertEqual(focused.runtimeIdentity, record.runtimeIdentity)
        XCTAssertEqual(focused.exitStatus, record.exitStatus)
        XCTAssertEqual(focused.status, record.status)
    }

    /// One run can name a file under `/private/var` and under `/var`, since a folder listing of the temporary
    /// folder gives the first and a standardized URL the second. Both spellings name the file and its origin.
    func testAFileNamedUnderPrivateVarIsTheSameFile() {
        let root = "/var/folders/xy/T/batch"
        let a = Self.file("\(root)/A/bams/A.bam", "a2", role: .output)
        let tempA = Self.file("/private\(root)/A/A_temp/A.bam", "a1")
        let record = Self.record([
            Self.step("move", inputs: [tempA], outputs: [
                Self.file("/private\(root)/A/bams/A.bam", "a1", role: .output, origin: tempA.path),
            ]),
            Self.step("probe A", inputs: [Self.file("/private\(root)/A/bams/A.bam", "a1")]),
            Self.step("count B", inputs: [Self.file("/private\(root)/B/bams/B.bam", "b2")]),
            Self.step("removal of the _temp folders", inputs: [Self.file("\(root)/A/A_temp/A.bam", "a1")]),
            Self.step("run", outputs: [a]),
        ])

        let focused = record.focusedOnLineage(of: a)
        XCTAssertEqual(Self.names(focused), ["move", "probe A", "removal of the _temp folders", "run"])
        XCTAssertEqual(focused.steps.first?.outputs, [a])
    }

    // MARK: - Records

    private static func file(
        _ path: String, _ digest: String, role: FileRole = .input, origin: String? = nil
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(path: path, checksumSHA256: digest, fileSize: 1, role: role, originPath: origin)
    }

    private static func step(
        _ name: String, inputs: [ProvenanceFileDescriptor] = [], outputs: [ProvenanceFileDescriptor] = []
    ) -> ProvenanceStep {
        ProvenanceStep(toolName: name, toolVersion: "1", argv: [name], inputs: inputs, outputs: outputs, exitStatus: 0)
    }

    /// A completed run of `steps` whose outputs are the last step's, as the run's own step of `build-db` names them.
    private static func record(_ steps: [ProvenanceStep], files: [ProvenanceFileDescriptor]? = nil) -> ProvenanceEnvelope {
        let outputs = steps.last?.outputs ?? []
        return ProvenanceEnvelope(
            workflowName: "lungfish build-db esviritu", toolName: "lungfish build-db esviritu", toolVersion: "1",
            argv: ["lungfish", "build-db", "esviritu", "/results"],
            files: files ?? steps.flatMap(\.inputs) + outputs, output: outputs.first, outputs: outputs, steps: steps,
            exitStatus: 0
        )
    }

    private static func names(_ envelope: ProvenanceEnvelope) -> [String] {
        envelope.steps.map(\.toolName)
    }
}
