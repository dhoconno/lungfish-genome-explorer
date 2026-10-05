// SRAToolkitSplit3ImportTests.swift - fetch sra download --use-toolkit then import fastq keeps every read in its role
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// Owner decision of 2026-10-05: the SRA Toolkit route runs `fasterq-dump
/// --split-3`. A paired run with spots that hold one read then arrives as
/// `<run>_1.fastq`, `<run>_2.fastq` and `<run>.fastq`, and `import fastq`
/// imports the third file as the run's unpaired reads. A single-end run
/// arrives as one file and imports as single reads. The toolkit writes the
/// files sra-tools 3.4.1 wrote for two public runs, so no test spawns a tool
/// or reaches the network.
final class SRAToolkitSplit3ImportTests: XCTestCase {

    private var root: URL!
    private var project: URL!
    private var recorded: SRAToolkitRecordedRunner!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-cli-split-3")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        recorded = SRAToolkitRecordedRunner(testFile: #filePath)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAPairedRunsReadsWithoutAMateImportAsUnpairedReads() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let files = try await download(run)
        XCTAssertEqual(files.map(\.lastPathComponent), ["\(run)_1.fastq", "\(run)_2.fastq", "\(run).fastq"])
        XCTAssertTrue(recorded.fasterqArguments.first?.contains("--split-3") == true)

        try await importFASTQ(files)

        let metadata = try importedMetadata(run)
        XCTAssertEqual(metadata.readClassification?.pairedReadCount, 258)
        XCTAssertEqual(metadata.readClassification?.unpairedReadCount, 6)
        XCTAssertEqual(metadata.ingestion?.originalFilenames, files.map(\.lastPathComponent))
    }

    func testASingleEndRunImportsAsSingleReads() async throws {
        let run = SRAToolkitRecordedRunner.singleEndRun
        let files = try await download(run)
        XCTAssertEqual(files.map(\.lastPathComponent), ["\(run).fastq"])

        try await importFASTQ(files)

        let metadata = try importedMetadata(run)
        XCTAssertEqual(metadata.ingestion?.pairingMode, .singleEnd)
        XCTAssertEqual(metadata.readClassification?.pairedReadCount ?? 0, 0)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle(run)))
        XCTAssertEqual(try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 1_000).headers.count, 53)
    }

    func testTheProvenanceRecordsTheSplit3Arguments() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        _ = try await download(run)

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: root.appendingPathComponent("download")))
        let fasterq = try XCTUnwrap(provenance.steps.first { $0.toolName == "fasterq-dump" })
        XCTAssertTrue(fasterq.command.contains("--split-3"), "\(fasterq.command)")
        XCTAssertFalse(fasterq.command.contains("--split-files"), "\(fasterq.command)")
    }

    // MARK: - Helpers

    /// Runs `fetch sra download <run> --use-toolkit` and returns the FASTQ
    /// files it wrote.
    private func download(_ run: String) async throws -> [URL] {
        let folder = root.appendingPathComponent("download", isDirectory: true)
        let service = SRAService(toolkitRunner: recorded.runner)
        let command = try SRADownloadSubcommand.parse([run, "--output-dir", folder.path, "--use-toolkit", "--quiet"])
        try await SRADownloadSubcommand.$makeService.withValue({ service }) {
            try await command.run()
        }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fastq" }
            .sorted { lhs, rhs in
                // Mates first, as the download lists them.
                (lhs.lastPathComponent.contains("_") ? 0 : 1, lhs.lastPathComponent)
                    < (rhs.lastPathComponent.contains("_") ? 0 : 1, rhs.lastPathComponent)
            }
    }

    /// Runs `import fastq <files>` as the window's arguments do.
    private func importFASTQ(_ files: [URL]) async throws {
        let command = try ImportCommand.FastqSubcommand.parse(files.map(\.path) + [
            "--project", project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage", "--no-color", "--quiet",
        ])
        try await command.run()
    }

    private func bundle(_ sample: String) -> URL {
        project.appendingPathComponent("Imports/\(sample).lungfishfastq", isDirectory: true)
    }

    private func importedMetadata(_ sample: String) throws -> PersistedFASTQMetadata {
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle(sample)), "no bundle for \(sample)")
        return try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
    }
}
