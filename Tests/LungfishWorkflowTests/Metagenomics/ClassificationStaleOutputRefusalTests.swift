// ClassificationStaleOutputRefusalTests.swift - A Kraken2 run never deletes its own input as a stale output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.1 lane L6, item 1. Before it runs, the classification removes the
// outputs an earlier run left in its folder, the provenance copies of
// transient inputs among them. A run whose input is one of those copies, as
// a replay of the recorded kraken2 step names it, deleted that input and
// then failed. The run now refuses before it removes anything.
//
// Review B-S4. The refused run then saved itself as a failed run into the
// folder, over the earlier run's `.lungfish-provenance.json`, so the earlier
// result kept its files and lost its only record of how they were made. A
// run that stops before anything ran, refused or failing its validation,
// now leaves that record byte for byte as it was.

import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class ClassificationStaleOutputRefusalTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classification-stale-outputs")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAnInputInsideTheReplayInputCopiesIsRefusedAndKept() async throws {
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("stand-in"))
        let outputDirectory = root.appendingPathComponent("kraken2-run", isDirectory: true)
        let replayCopies = outputDirectory
            .appendingPathComponent(".lungfish-provenance/intermediates/classification-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: replayCopies, withIntermediateDirectories: true)
        let input = replayCopies.appendingPathComponent("input-1-reads.fastq")
        try ReadSetFixtures.fastq(["r1", "r2"]).write(to: input, atomically: true, encoding: .utf8)
        let earlierReport = outputDirectory.appendingPathComponent("classification.kreport")
        try "earlier report\n".write(to: earlierReport, atomically: true, encoding: .utf8)
        let earlierRecord = try Self.writeEarlierRecord(in: outputDirectory)
        let config = ClassificationConfig(
            inputFiles: [input],
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databasePath: kraken2.databaseURL,
            outputDirectory: outputDirectory
        )

        do {
            _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
            XCTFail("an input inside an output the run removes must refuse the run")
        } catch {
            XCTAssertEqual(
                error as? OutputReplacementRefusal,
                .inputInsideOutput(input: input.standardizedFileURL.path, output: replayCopies.standardizedFileURL.path),
                "\(error)"
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path), "the input survives")
        XCTAssertEqual(try String(contentsOf: earlierReport, encoding: .utf8), "earlier report\n", "nothing is removed")
        XCTAssertThrowsError(try kraken2.argv(), "kraken2 never runs")
        XCTAssertEqual(
            try Data(contentsOf: Self.recordURL(in: outputDirectory)), earlierRecord,
            "the earlier run keeps its record, byte for byte"
        )
    }

    func testAFailedValidationInAnEarlierRunsFolderKeepsItsRecord() async throws {
        let kraken2 = try StandInKraken2(root: root.appendingPathComponent("stand-in"))
        let outputDirectory = root.appendingPathComponent("kraken2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let earlierRecord = try Self.writeEarlierRecord(in: outputDirectory)
        let missingInput = root.appendingPathComponent("moved-away.fastq")
        let config = ClassificationConfig(
            inputFiles: [missingInput],
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databasePath: kraken2.databaseURL,
            outputDirectory: outputDirectory
        )

        do {
            _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
            XCTFail("a missing input must fail the validation")
        } catch {
            guard case .inputFileNotFound? = error as? ClassificationConfigError else {
                return XCTFail("expected inputFileNotFound, got \(error)")
            }
        }
        XCTAssertThrowsError(try kraken2.argv(), "kraken2 never runs")
        XCTAssertEqual(
            try Data(contentsOf: Self.recordURL(in: outputDirectory)), earlierRecord,
            "a run that never ran leaves the earlier run's record as it was"
        )
    }

    // MARK: - Helpers

    static func recordURL(in folder: URL) -> URL {
        folder.appendingPathComponent(ProvenanceWriter.provenanceFilename)
    }

    /// Writes a stand-in for the record an earlier run saved in `folder` and
    /// returns its bytes.
    static func writeEarlierRecord(in folder: URL) throws -> Data {
        let bytes = Data(#"{"workflowName":"Metagenomics Classification","note":"the earlier run"}"#.utf8)
        try bytes.write(to: recordURL(in: folder))
        return bytes
    }
}
