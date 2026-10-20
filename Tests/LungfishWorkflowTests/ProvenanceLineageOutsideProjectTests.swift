// ProvenanceLineageOutsideProjectTests.swift - Lineage adopts a record outside the project only on a checksum match
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// Lane 13.34 M3 (decision V3-4). The resolver follows an input to the record the sidecar lookup finds
/// for it. Inside the project a path match is enough. Outside it, files at one path get replaced, so a
/// record counts only when the input's recorded checksum is not empty and equals the checksum of one of
/// the record's outputs. Every case lives under `TestTempDirectory`, and the outside file's sidecar sits
/// beside it, so the lookup finds it by its exact name and climbs no folder.
final class ProvenanceLineageOutsideProjectTests: XCTestCase {
    private var scratch: URL!
    private var caseRoot: URL!
    private var project: URL!

    private let checksumA = String(repeating: "a", count: 64)
    private let checksumB = String(repeating: "b", count: 64)
    private let recordName = "record of the input"
    private let runName = "run with an input"

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "lineage-outside")
        caseRoot = scratch.appendingPathComponent("case", isDirectory: true).standardizedFileURL
        project = caseRoot.appendingPathComponent("P.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Analyses/run", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - Outside the project

    /// `Loose/reads.fastq` holds bytes B and its sidecar records the checksum of bytes A at the same
    /// path. The run in the project recorded the checksum of bytes B. The record describes other bytes,
    /// so it is not lineage. At the base it is adopted by path.
    func testAnOutsideRecordOfOtherBytesAtTheSamePathIsNotLineage() throws {
        let names = try resolvedNames(
            inputFolder: caseRoot.appendingPathComponent("Loose", isDirectory: true),
            inputChecksum: checksumB,
            recordedOutputChecksum: checksumA
        )
        XCTAssertEqual(names, [runName])
    }

    /// The same, with the sidecar recording the checksum of bytes B. The record describes the bytes the
    /// run read, so it is the only record of where the input came from and it stays lineage. This holds
    /// at the base and after the fix.
    func testAnOutsideRecordOfTheSameBytesStaysLineage() throws {
        let names = try resolvedNames(
            inputFolder: caseRoot.appendingPathComponent("Loose", isDirectory: true),
            inputChecksum: checksumB,
            recordedOutputChecksum: checksumB
        )
        XCTAssertEqual(names, [recordName, runName])
    }

    /// An input recorded with no checksum cannot show that the record describes its bytes, so a record
    /// outside the project is not lineage for it. At the base it is adopted by path.
    func testAnOutsideRecordForAnInputRecordedWithNoChecksumIsNotLineage() throws {
        let names = try resolvedNames(
            inputFolder: caseRoot.appendingPathComponent("Loose", isDirectory: true),
            inputChecksum: "",
            recordedOutputChecksum: checksumA
        )
        XCTAssertEqual(names, [runName])
    }

    // MARK: - Inside the project

    /// Nothing inside the project moves. A record beside a project file that names its path is adopted by
    /// path, whatever checksum it holds. This holds at the base and after the fix.
    func testAnInsideRecordOfOtherBytesAtTheSamePathStaysLineage() throws {
        let names = try resolvedNames(
            inputFolder: project.appendingPathComponent("Imports", isDirectory: true),
            inputChecksum: checksumB,
            recordedOutputChecksum: checksumA
        )
        XCTAssertEqual(names, [recordName, runName])
    }

    // MARK: - Fixtures

    /// Writes `reads.fastq` in `inputFolder` with its sidecar beside it, then a run record in the project
    /// that names the file as an input, and returns the names of the records the walk gathers, upstream
    /// first.
    private func resolvedNames(
        inputFolder: URL,
        inputChecksum: String,
        recordedOutputChecksum: String
    ) throws -> [String] {
        try FileManager.default.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        let input = inputFolder.appendingPathComponent("reads.fastq")
        try Data("bytes b\n".utf8).write(to: input)
        try write(
            run(recordName, inputs: [], outputs: [record(input.path, recordedOutputChecksum, .output)]),
            to: ProvenanceRecorder.fileSidecarURL(for: input)
        )
        let sidecar = project.appendingPathComponent("Analyses/run/.lungfish-provenance.json")
        try write(
            run(
                runName,
                inputs: [record(input.path, inputChecksum, .input)],
                outputs: [record(project.appendingPathComponent("Analyses/run/out.txt").path, checksumA, .output)]
            ),
            to: sidecar
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        return ProvenanceLineageResolver()
            .resolve(envelope: envelope, sidecarURL: sidecar)
            .map(\.envelope.workflowName)
    }

    private func record(_ path: String, _ checksum: String, _ role: FileRole) -> FileRecord {
        FileRecord(path: path, sha256: checksum, sizeBytes: 4, format: nil, role: role)
    }

    private func run(_ name: String, inputs: [FileRecord], outputs: [FileRecord]) -> WorkflowRun {
        WorkflowRun(
            name: name,
            endTime: Date(),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: "pin-tool", toolVersion: "1.0",
                    command: ["pin-tool", "run"],
                    inputs: inputs, outputs: outputs,
                    exitCode: 0, wallTime: 1
                ),
            ]
        )
    }

    /// A legacy `WorkflowRun` sidecar written verbatim, with absolute paths and no placeholders.
    private func write(_ run: WorkflowRun, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: url, options: .atomic)
    }
}
