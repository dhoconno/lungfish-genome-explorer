// ClassifyCommandFailureRecordTests.swift - A conda classify run that never ran keeps the earlier run's record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Review B-S4. `conda classify` records every failed run in its output
/// folder. When the classification stopped before anything ran, refused
/// because an input sits inside an output it would remove, or failing its
/// validation, the record replaced the `.lungfish-provenance.json` of the
/// earlier run in that folder, which kept its files and lost its only record.
/// The command now leaves the folder's record as it found it whenever the
/// classification stopped before anything ran and recorded nothing, and
/// records every other failure as before.
final class ClassifyCommandFailureRecordTests: XCTestCase {

    private var root: URL!
    private var output: URL!
    private var input: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classify-failure-record")
        output = root.appendingPathComponent("kraken2-run", isDirectory: true)
        let copies = output.appendingPathComponent(".lungfish-provenance/intermediates/classification-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        input = copies.appendingPathComponent("input-1-reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: input, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testARefusedRunLeavesTheEarlierRunsRecordAsItWas() throws {
        let earlier = try writeEarlierRecord()

        try record(refusal, recordAtStart: earlier)

        XCTAssertEqual(try Data(contentsOf: recordURL), earlier, "the earlier run keeps its record, byte for byte")
    }

    func testARefusedRunInAFolderWithoutARecordWritesNone() throws {
        try record(refusal, recordAtStart: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path), "a run that never ran records nothing")
    }

    func testAFailedValidationLeavesTheEarlierRunsRecordAsItWas() throws {
        let earlier = try writeEarlierRecord()

        try record(ClassificationConfigError.inputFileNotFound(input), recordAtStart: earlier)

        XCTAssertEqual(try Data(contentsOf: recordURL), earlier)
    }

    func testAFailedValidationThePipelineRecordedIsRecordedAsBefore() throws {
        // The folder held no record, so the pipeline saved its failed run,
        // which the command's record of the failure takes in.
        try Data(#"{"workflowName":"Metagenomics Classification"}"#.utf8).write(to: recordURL)

        try record(ClassificationConfigError.inputFileNotFound(input), recordAtStart: nil)

        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: output)?.workflowName, "lungfish.classify")
    }

    func testAFailureToCreateTheOutputFolderIsRecordedAsBefore() throws {
        // No earlier record can sit in a folder that could not be created,
        // so the command records the failure as it always did.
        let creation = ClassificationConfigError.outputDirectoryCreationFailed(output, CocoaError(.fileWriteNoPermission))

        try record(creation, recordAtStart: nil)

        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: output)?.workflowName, "lungfish.classify")
    }

    func testAFailureAfterTheRunStartedIsRecordedAsBefore() throws {
        let earlier = try writeEarlierRecord()

        try record(ClassificationPipelineError.kraken2Failed(exitCode: 37, stderr: "kraken2 failed"), recordAtStart: earlier)

        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: output)?.workflowName, "lungfish.classify")
    }

    func testARefusalAfterTheCommandWroteItsOwnRecordIsRecordedAsBefore() throws {
        // A materialized input's record replaced the earlier one before the
        // classification refused, so the folder holds this command's record.
        let earlier = try writeEarlierRecord()
        try Data(#"{"workflowName":"lungfish.classify.input-materialization"}"#.utf8).write(to: recordURL)

        try record(refusal, recordAtStart: earlier)

        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: output)?.workflowName, "lungfish.classify")
    }

    // MARK: - Helpers

    private var recordURL: URL {
        output.appendingPathComponent(ProvenanceWriter.provenanceFilename)
    }

    private var refusal: OutputReplacementRefusal {
        .inputInsideOutput(
            input: input.path,
            output: input.deletingLastPathComponent().path
        )
    }

    private func writeEarlierRecord() throws -> Data {
        let bytes = Data(#"{"workflowName":"Metagenomics Classification","note":"the earlier run"}"#.utf8)
        try bytes.write(to: recordURL)
        return bytes
    }

    /// Records `error` as the failure of a classification that reached the
    /// pipeline, as `run()` does.
    private func record(_ error: Error, recordAtStart: Data?) throws {
        let argv = ["lungfish-cli", "conda", "classify", input.path, "--db", "FixtureDB", "--output-dir", output.path]
        let command = try ClassifyCommand.parse(Array(argv.dropFirst(3)))
        var context = ClassifyFailureProvenanceContext(outputDirectory: output, originalInputURLs: [input])
        context.stage = .pipeline
        context.pipelineStarted = true
        try ClassifyCommand.recordFailure(
            error,
            command: command,
            context: context,
            argv: argv,
            profileState: "failed",
            startedAt: Date(),
            provenanceRecordAtStart: recordAtStart
        )
    }
}
