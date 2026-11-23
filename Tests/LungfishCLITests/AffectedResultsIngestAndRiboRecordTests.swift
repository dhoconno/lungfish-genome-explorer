// AffectedResultsIngestAndRiboRecordTests.swift - The kinds of the records `fastq ingest --pair` and `fastq ribodetector` write for two loose files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// FIX-ROUTES-7 (BIO-ROUTES-5 items 3 and 4). `AffectedResults.kind(of:)` reads a record's root name and its keys, so the
/// kind of each route is pinned against the record its writer made, with no tool run. The pins of the writers that need the
/// CLI sit here, since `AffectedResultsLoosePairAndImportTests` cannot reach it. The writer of `fastq deacon-ribo` runs only
/// after Deacon, so its pin builds the envelope with the writer's name and keys, in that class.
///
/// - A, `fastq ingest R1 --pair R2`: the record is made by `FastqIngestRun.writeRecord`, the call the pipeline makes after
///   its tools. The pipeline's result is made by hand.
/// - B, `fastq ribodetector R1 R2`: the real command writes the record, with the recording stand-in of
///   `LoosePairIngestAndRiboRoutesTests` for the tool.
final class AffectedResultsIngestAndRiboRecordTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "affected-ingest-ribo").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - A, fastq ingest --pair

    func testTheRecordOfAnIngestOfTwoLooseFilesIsTheIngestLoosePairKind() async throws {
        let (r1, r2) = try inStepPair()
        let record = try await ingestRecord(inputs: [r1, r2])
        XCTAssertEqual(record.workflowName, "lungfish fastq ingest")
        XCTAssertEqual(AffectedResults.kind(of: record)?.rawValue, "fastqIngestLoosePair")
    }

    /// Guard: one file records `pair` as null and is no kind.
    func testTheRecordOfAnIngestOfOneFileIsNoKind() async throws {
        let single = try writeMates("S.fastq", names: (1...20).map { "frag\($0)" })
        let record = try await ingestRecord(inputs: [single])
        XCTAssertEqual(record.workflowName, "lungfish fastq ingest")
        XCTAssertEqual(AffectedResults.kind(of: record)?.rawValue, nil)
    }

    /// BIO-ROUTES-5 item 4. When a record already stands in the folder, `writeRecord` merges into it
    /// (`InPlaceIngestionProvenance.swift:42`), and the merged root keeps the name of the record that stood, so the ingest
    /// shows only as its step and its merged `input` and `pair` options.
    func testAnIngestOfTwoLooseFilesMergedOverAStandingDownloadRecordIsTheIngestLoosePairKind() async throws {
        let (r1, r2) = try inStepPair()
        try await writeStandingDownloadRecord(in: root)
        let record = try await ingestRecord(inputs: [r1, r2])
        XCTAssertEqual(record.workflowName, "SRA download")
        XCTAssertEqual(AffectedResults.kind(of: record)?.rawValue, "fastqIngestLoosePair")
    }

    // MARK: - B, fastq ribodetector R1 R2

    func testTheRecordOfARiboDetectorRunOnTwoLooseFilesIsTheRiboFilterLoosePairKind() async throws {
        let (r1, r2) = try inStepPair()
        let record = try await riboDetectorRecord(inputs: [r1, r2])
        XCTAssertEqual(record.workflowName, "RiboDetector FASTQ filter")
        XCTAssertEqual(AffectedResults.kind(of: record)?.rawValue, "fastqRiboFilterLoosePair")
    }

    /// Guard: one file is no kind.
    func testTheRecordOfARiboDetectorRunOnOneFileIsNoKind() async throws {
        let single = try writeMates("S.fastq", names: (1...200).map { "frag\($0)" })
        let record = try await riboDetectorRecord(inputs: [single])
        XCTAssertEqual(record.workflowName, "RiboDetector FASTQ filter")
        XCTAssertEqual(AffectedResults.kind(of: record)?.rawValue, nil)
    }

    // MARK: - The records the writers make

    /// The record `FastqIngestRun.writeRecord` writes into the folder of `inputs`, with no tool run: the pipeline's result,
    /// the output and its digests are made by hand, and the writer is the one `fastq ingest` calls after its pipeline.
    func ingestRecord(inputs: [URL]) async throws -> ProvenanceEnvelope {
        let arguments = [inputs[0].path] + (inputs.count == 2 ? ["--pair", inputs[1].path] : [])
            + ["--binning", "none", "--skip-clumpify"]
        let command = try FastqIngestSubcommand.parse(arguments)
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

    /// A download-style record standing in `folder`, the history a file brings with it. `fastq ingest` reads the folder's
    /// root record first (`InPlaceIngestionProvenance.swift:15`).
    func writeStandingDownloadRecord(in folder: URL) async throws {
        let runID = await ProvenanceRecorder.shared.beginRun(
            name: "SRA download",
            parameters: ["accession": .string("SRR0000001")]
        )
        await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
        try await ProvenanceRecorder.shared.save(runID: runID, to: folder)
    }

    /// The record `fastq ribodetector` writes, with the recording stand-in for the tool (`LoosePairIngestAndRiboRoutesTests`).
    func riboDetectorRecord(inputs: [URL]) async throws -> ProvenanceEnvelope {
        let fake = LoosePairIngestAndRiboRoutesTests.RecordingRiboDetector()
        let original = FastqRiboDetectorSubcommand.toolRunner
        FastqRiboDetectorSubcommand.toolRunner = fake
        defer { FastqRiboDetectorSubcommand.toolRunner = original }
        let output = root.appendingPathComponent("ribo-out-\(UUID().uuidString)", isDirectory: true)
        try await FastqRiboDetectorSubcommand.parse(inputs.map(\.path) + ["--read-length", "60", "-o", output.path]).run()
        XCTAssertEqual(fake.invocations.count, 1)
        return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
    }

    // MARK: - Fixtures

    func inStepPair() throws -> (URL, URL) {
        (try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" }),
         try writeMates("S_R2.fastq", names: (1...200).map { "frag\($0)/2" }))
    }

    func writeMates(_ name: String, names: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(ReadSetFixtures.fastq(names).utf8).write(to: url)
        return url
    }
}
