// FastqIngestKeepsExtractionRecordTests.swift - An in-place ingest keeps the extraction record of the file it replaces
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep lane RECORDS, PAIRING-RECORD-LOST (BIO review of PAIRING, backlog 1). The record that stands in a taxa
// collection's folder is the root record, and `fastq ingest` merged it and never read the per-file record that the
// extraction wrote beside the file. `--delete-originals` then removed that record with the original, so the folder lost
// the source FASTQ's name and digest, `resolvedTaxIds`, `sourceFiles` and the per-taxon count. `writeRecord` now adds the
// steps of the input's own record to the run before the merge, when that record is not the one the merge took. The pin
// calls the writer the pipeline calls after its tools, as `AffectedResultsIngestAndRiboRecordTests` does, so no tool
// runs and no number changes.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class FastqIngestKeepsExtractionRecordTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ingest-keeps-extraction").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The defect. A folder with a root record and the extraction's record of the input: after the ingest the merged record
    /// names the source FASTQ with its digest and holds the extraction's options, and the root keeps its own name and the
    /// ingest stays the last step.
    func testTheMergedRecordHoldsTheFactsOfTheInputsExtractionRecord() async throws {
        let source = root.appendingPathComponent("SRR12486983.fastq.gz")
        try Data("the reads the extraction read".utf8).write(to: source)
        let sourceRecord = ProvenanceRecorder.fileRecord(url: source, format: .fastq, role: .input)
        let input = root.appendingPathComponent("HSV-1_taxid10298.fastq")
        try Data(ReadSetFixtures.fastq((1...4).map { "frag\($0)/1" }).utf8).write(to: input)
        try await writeStandingRootRecord(in: root)
        try await writeExtractionRecord(of: input, source: source)
        let ownRecord = ProvenanceRecorder.fileSidecarURL(for: input)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownRecord.path), "the extraction's record stands beside the file")

        let merged = try await ingestRecord(input: input)

        XCTAssertEqual(merged.workflowName, "lungfish extract taxa-collection", "the root record keeps its name")
        XCTAssertEqual(merged.steps.last?.toolName, "FASTQIngestionPipeline", "the ingest is the last step")
        let extraction = merged.steps.filter { $0.toolName == "TaxonomyExtractionPipeline" }
        XCTAssertEqual(extraction.count, 1, "the extraction's step is in the merged record")
        XCTAssertTrue(
            merged.steps.flatMap(\.inputs).contains {
                URL(fileURLWithPath: $0.path).lastPathComponent == "SRR12486983.fastq.gz"
                    && $0.checksumSHA256 == sourceRecord.sha256
            },
            "the source FASTQ with its digest"
        )
        let facts = extraction.first?.resolvedOptions
        XCTAssertEqual(facts?["resolvedTaxIds"], .array([.integer(10298), .integer(10299)]))
        XCTAssertEqual(facts?["extractedReads"], .integer(8), "the per-taxon count")
        guard case .array(let sourceFiles)? = facts?["sourceFiles"] else {
            return XCTFail("the extraction's sourceFiles are not in the merged record")
        }
        XCTAssertEqual(
            sourceFiles.compactMap(\.stringValue).map { URL(fileURLWithPath: $0).lastPathComponent },
            ["SRR12486983.fastq.gz"]
        )
    }

    /// Guard. A folder with a root record and no record of the input's own merges as before: the ingest is the one step added.
    func testAFolderWithNoRecordOfTheInputsOwnMergesAsBefore() async throws {
        let input = root.appendingPathComponent("HSV-1_taxid10298.fastq")
        try Data(ReadSetFixtures.fastq((1...4).map { "frag\($0)/1" }).utf8).write(to: input)
        try await writeStandingRootRecord(in: root)
        let standing = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: root))

        let merged = try await ingestRecord(input: input)

        XCTAssertEqual(merged.workflowName, "lungfish extract taxa-collection")
        XCTAssertEqual(merged.steps.count, standing.steps.count + 1)
        XCTAssertEqual(merged.steps.last?.toolName, "FASTQIngestionPipeline")
    }

    // MARK: - The records the extraction wrote

    /// The folder's root record, as `extract taxa-collection` leaves it.
    func writeStandingRootRecord(in folder: URL) async throws {
        let runID = await ProvenanceRecorder.shared.beginRun(
            name: "lungfish extract taxa-collection",
            parameters: ["collectionId": .string("sti-pathogens")]
        )
        await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
        try await ProvenanceRecorder.shared.save(runID: runID, to: folder)
    }

    /// The per-file record the extraction writes beside a file (`TaxonomyExtractionPipeline.recordProvenance`): the run
    /// recorded for the file, focused on it. The extraction's options are the run's, and its step names the source FASTQ.
    func writeExtractionRecord(of input: URL, source: URL) async throws {
        let recorder = ProvenanceRecorder.shared
        let runID = await recorder.beginRun(
            name: "Taxonomy Read Extraction",
            parameters: [
                "taxIds": .array([.integer(10298)]),
                "resolvedTaxIds": .array([.integer(10298), .integer(10299)]),
                "extractedReads": .integer(8),
                "sourceFiles": .array([.string(source.path)]),
            ]
        )
        let output = ProvenanceRecorder.fileRecord(url: input, format: .fastq, role: .output)
        await recorder.recordStep(
            runID: runID,
            toolName: "TaxonomyExtractionPipeline",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish-cli", "extract", "taxa-collection", "--target", "10298,children,HSV-1"],
            inputs: [ProvenanceRecorder.fileRecord(url: source, format: .fastq, role: .input)],
            outputs: [output],
            exitCode: 0,
            wallTime: 1
        )
        await recorder.completeRun(runID, status: .completed)
        let canonical = await recorder.canonicalEnvelope(for: runID)
        let envelope = try XCTUnwrap(canonical)
        try ProvenanceWriter().write(
            envelope.focusedOnOutput(ProvenanceFileDescriptor(fileRecord: output)),
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: input)
        )
    }

    // MARK: - The record the ingest writes

    /// The record `FastqIngestRun.writeRecord` writes into the folder of `input`, with no tool run (the pipeline's result,
    /// the output and its digests are made by hand), merged over the record that stands there.
    func ingestRecord(input: URL) async throws -> ProvenanceEnvelope {
        let command = try FastqIngestSubcommand.parse([input.path, "--binning", "none", "--skip-clumpify"])
        let urls = command.inputURLs()
        let options = command.runOptions()
        let run = FastqIngestRun(
            inputs: urls,
            options: options,
            command: command.replayArgv(),
            parameters: command.provenanceParameters(inputs: urls),
            defaults: FastqIngestSubcommand.provenanceDefaults,
            events: CLIEventEmitter(enabled: false, emit: { _ in }),
            clock: ProvenanceRunClock()
        )
        let folder = urls[0].deletingLastPathComponent()
        let output = FastqIngestRun.finalOutputURL(folder: folder, inputs: urls)
        try Data("x".utf8).write(to: output)
        let sidecarURL = FASTQMetadataStore.metadataURL(for: output)
        try Data("{}".utf8).write(to: sidecarURL)
        let originals = urls.map {
            FileRecord(path: $0.path, sha256: String(repeating: "a", count: 64), sizeBytes: 1, format: .fastq, role: .input)
        }
        let outputRecord = FileRecord(
            path: output.path, sha256: String(repeating: "b", count: 64), sizeBytes: 1, format: .fastq, role: .output
        )
        let result = FASTQIngestionResult(
            outputFile: output,
            wasClumpified: false,
            qualityBinning: options.binning,
            originalFilenames: urls.map(\.lastPathComponent),
            originalSizeBytes: 1,
            finalSizeBytes: 1,
            pairingMode: options.pairingMode
        )
        try await run.writeRecord(
            result: result,
            staged: output,
            output: output,
            outputRecord: outputRecord,
            sidecarURL: sidecarURL,
            originals: originals,
            folder: folder
        )
        return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder))
    }
}
