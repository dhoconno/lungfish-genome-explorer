// SRAWindowToolkitSplit3Tests.swift - The window imports a toolkit run's reads without a mate as unpaired reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Owner decision of 2026-10-05: the SRA Toolkit route runs `fasterq-dump
/// --split-3`, so a paired run's reads without a mate arrive in
/// `<run>.fastq` beside the two mate files, and the window imports them as
/// the run's unpaired reads. A single-end run still imports as single reads.
/// The toolkit writes the files sra-tools 3.4.1 wrote for two public runs,
/// and the import runs the shared code `lungfish-cli import fastq` runs, so
/// no test spawns a tool or reaches the network.
final class SRAWindowToolkitSplit3Tests: XCTestCase {

    private var root: URL!
    private var recorded: SRAToolkitRecordedRunner!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-window-split-3")
        recorded = SRAToolkitRecordedRunner(testFile: #filePath)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAToolkitRunsReadsWithoutAMateImportAsUnpairedReads() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let staged = try await stageOnTheToolkitRoute(run)
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.download.source, .sraToolkit)
        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["\(run)_1.fastq", "\(run)_2.fastq", "\(run).fastq"])
        XCTAssertTrue(recorded.fasterqArguments.first?.contains("--split-3") == true)

        let metadata = try await importAsTheCommandDoes(staged.reads.files)

        XCTAssertEqual(metadata.readClassification?.pairedReadCount, 258)
        XCTAssertEqual(metadata.readClassification?.unpairedReadCount, 6)
    }

    func testAToolkitSingleEndRunImportsAsSingleReads() async throws {
        let run = SRAToolkitRecordedRunner.singleEndRun
        let staged = try await stageOnTheToolkitRoute(run)
        defer { staged.removeFolder() }
        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), ["\(run).fastq"])
        XCTAssertNil(staged.reads.r2)

        let metadata = try await importAsTheCommandDoes(staged.reads.files, pairing: .auto)

        XCTAssertEqual(metadata.ingestion?.pairingMode, .singleEnd)
        XCTAssertEqual(metadata.readClassification?.pairedReadCount ?? 0, 0)
    }

    // MARK: - Helpers

    /// Stages the run on the toolkit route, as the window does when ENA
    /// cannot serve it.
    private func stageOnTheToolkitRoute(_ run: String) async throws -> SRAWindowStagedRun {
        let service = SRAService(toolkitRunner: recorded.runner)
        return try await SRAWindowRunDownload.stage(
            accession: run,
            route: .sraToolkit(enaRecord: nil, reason: "ENA has no record of \(run)"),
            in: root.appendingPathComponent("batch", isDirectory: true),
            mirrorFile: { _, _, _ in
                XCTFail("the toolkit route fetches nothing from ENA's mirror")
                return Data()
            },
            toolkit: { _, folder in
                try await service.downloadFASTQ(accession: run, outputDir: folder)
            }
        )
    }

    /// Runs what `lungfish-cli import fastq <files> --no-optimize-storage`
    /// runs, and returns the imported bundle's FASTQ metadata.
    private func importAsTheCommandDoes(
        _ files: [URL],
        pairing: FASTQBatchImporter.ImportPairing = .paired
    ) async throws -> PersistedFASTQMetadata {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let check = FASTQBatchImporter.checkingUnpairedReads(
            FASTQBatchImporter.applyPairing(pairing, to: FASTQBatchImporter.detectPairs(from: files))
        )
        XCTAssertEqual(check.samples.count, 1, "the run's files are one sample")
        XCTAssertTrue(check.warnings.isEmpty, "\(check.warnings)")
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: check.samples,
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project,
                platform: .given(.illumina),
                qualityBinning: QualityBinningScheme.none,
                optimizeStorage: false,
                threads: 1,
                pairing: pairing
            )
        )
        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        let bundle = FASTQBatchImporter.bundleOutputURL(for: try XCTUnwrap(check.samples.first), in: project)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        return try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
    }
}
