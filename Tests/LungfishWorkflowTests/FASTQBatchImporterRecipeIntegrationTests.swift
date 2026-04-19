// FASTQBatchImporterRecipeIntegrationTests.swift - Real-tool coverage for importer recipe execution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO

final class FASTQBatchImporterRecipeIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private let runner = NativeToolRunner.shared

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterRecipeIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testRunBatchImportSkippedLeadingStepStillSucceedsForPairedFASTQ() async throws {
        try await requireManagedTools([.fastp, .reformat])

        let pair = SamplePair(
            sampleName: "sample",
            r1: tempDir.appendingPathComponent("sample_R1.fastq"),
            r2: tempDir.appendingPathComponent("sample_R2.fastq")
        )
        try writeFASTQ(
            to: pair.r1,
            records: [
                ("@pair1/1", "ACGTACGTACGTACGT", "IIIIIIIIIIII5555"),
                ("@pair2/1", "TGCATGCATGCATGCA", "IIIIIIIIIIII5555"),
            ]
        )
        try writeFASTQ(
            to: try XCTUnwrap(pair.r2),
            records: [
                ("@pair1/2", "TGCATGCATGCATGCA", "IIIIIIIIIIII5555"),
                ("@pair2/2", "ACGTACGTACGTACGT", "IIIIIIIIIIII5555"),
            ]
        )

        let recipe = ProcessingRecipe(
            name: "Skipped Primer Then Quality Trim",
            steps: [
                FASTQDerivativeOperation(
                    kind: .primerRemoval,
                    createdAt: .distantPast,
                    primerSource: .literal,
                    primerReadMode: .paired,
                    primerTrimMode: .paired,
                    primerAnchored5Prime: true,
                    primerAnchored3Prime: true,
                    primerMinimumOverlap: 12
                ),
                FASTQDerivativeOperation(
                    kind: .qualityTrim,
                    createdAt: .distantPast,
                    qualityThreshold: 20,
                    windowSize: 4,
                    qualityTrimMode: .cutRight
                )
            ]
        )
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: tempDir.appendingPathComponent("Project.lungfish"),
            recipe: recipe,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 2
        )

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config
        )

        XCTAssertEqual(result.completed, 1, "Importer should create a bundle even after skipping an unsupported leading step")
        XCTAssertEqual(result.failed, 0, "Importer should not fail when running fastp on interleaved input")
        XCTAssertTrue(result.errors.isEmpty)

        let bundleURL = config.projectDirectory
            .appendingPathComponent("Imports")
            .appendingPathComponent("sample.lungfishfastq")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent("sample.fastq.gz").path
            ),
            "Imported bundle should contain the final FASTQ payload"
        )
    }

    func testRunBatchImportPairedEndMergeRecipeSucceedsForPairedFASTQ() async throws {
        try await requireManagedTools([.bbmerge, .reformat, .pigz])

        let pair = SamplePair(
            sampleName: "merge-sample",
            r1: tempDir.appendingPathComponent("merge_R1.fastq"),
            r2: tempDir.appendingPathComponent("merge_R2.fastq")
        )
        try writeFASTQ(
            to: pair.r1,
            records: [
                ("@pair1/1", "ACGTACGTACGT", "IIIIIIIIIIII"),
                ("@pair2/1", "TTTTCCCCAAAA", "IIIIIIIIIIII"),
            ]
        )
        try writeFASTQ(
            to: try XCTUnwrap(pair.r2),
            records: [
                ("@pair1/2", "ACGTACGTACGT", "IIIIIIIIIIII"),
                ("@pair2/2", "TTTTCCCCAAAA", "IIIIIIIIIIII"),
            ]
        )

        let recipe = ProcessingRecipe(
            name: "Paired Merge",
            steps: [
                FASTQDerivativeOperation(
                    kind: .pairedEndMerge,
                    createdAt: .distantPast,
                    mergeStrictness: .strict,
                    mergeMinOverlap: 10
                )
            ]
        )
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: tempDir.appendingPathComponent("MergeProject.lungfish"),
            recipe: recipe,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 2
        )

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config
        )

        XCTAssertEqual(result.completed, 1, "Importer should create a bundle for paired-end merge recipes")
        XCTAssertEqual(result.failed, 0, "Importer should not fail when bbmerge reads interleaved input")
        XCTAssertTrue(result.errors.isEmpty)

        let bundleURL = config.projectDirectory
            .appendingPathComponent("Imports")
            .appendingPathComponent("merge-sample.lungfishfastq")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent("merge-sample.fastq.gz").path
            ),
            "Merged bundle should contain the final FASTQ payload"
        )
    }

    private func requireManagedTools(_ tools: [NativeTool]) async throws {
        for tool in tools {
            guard (try? await runner.toolPath(for: tool)) != nil else {
                throw XCTSkip("Managed \(tool.rawValue) is not available")
            }
        }
    }

    private func writeFASTQ(
        to url: URL,
        records: [(header: String, sequence: String, quality: String)]
    ) throws {
        let content = records.map { record in
            [
                record.header,
                record.sequence,
                "+",
                record.quality,
            ].joined(separator: "\n")
        }.joined(separator: "\n")
        try content.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
