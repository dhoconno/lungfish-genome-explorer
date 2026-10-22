// FASTQBatchImporterStorageToolTests.swift - the import stores a merging recipe's output through Trim Galore (CHTC lane C2-TRIMGALORE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Until 2026-10-22 the batch importer refused Trim Galore for a recipe whose output mixes merged reads with pairs,
/// before its first step, because Trim Galore could not take that file. The storage step now splits it by mate name as
/// the bbtools route does, so the same import runs and stores the same reads with either tool.
final class FASTQBatchImporterStorageToolTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterStorageToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Imports eight pairs that stay pairs and six that merge, through a recipe that keeps both, and returns the
    /// import's result with the FASTQ it stored.
    private func importPairs(
        with tool: ClumpingTool, label: String
    ) async throws -> (result: FASTQBatchImporter.ImportResult, stored: URL?) {
        let input = tempDir.appendingPathComponent("\(label)-input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let r1 = input.appendingPathComponent("s_R1.fastq")
        let r2 = input.appendingPathComponent("s_R2.fastq")
        try MixedStorageFASTQ.writeReadPairs(r1: r1, r2: r2, apart: 8, overlapping: 6)
        let recipe = Recipe(
            id: "merge-keep-unmerged", name: "Merge and keep the unmerged pairs", requiredInput: .paired,
            steps: [RecipeStep(type: "fastp-merge", label: nil, params: ["keepUnmerged": .bool(true)])]
        )
        let project = tempDir.appendingPathComponent("\(label).lungfish", isDirectory: true)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: project, platform: .illumina,
            newRecipe: recipe,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: true,
            clumpingTool: tool,
            threads: 2
        )

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: "s", r1: r1, r2: r2)], config: config
        )

        let files = (try? FileManager.default.subpathsOfDirectory(atPath: project.path)) ?? []
        let stored = files.first { $0.hasSuffix(".fastq.gz") && $0.contains(".lungfishfastq") }
            .map { project.appendingPathComponent($0) }
        return (result, stored)
    }

    func testAMergingRecipeStoresThroughTrimGaloreAsThroughBBTools() async throws {
        _ = try await ToolAvailability.require("fastp", environment: "fastp")
        _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")
        _ = try await ToolAvailability.require("trim_galore", environment: "trim_galore")

        let reference = try await importPairs(with: .bbtools, label: "bbtools")
        XCTAssertEqual(reference.result.completed, 1, "\(reference.result.errors)")
        let referenceLayout = try MixedStorageFASTQ.layout(of: try XCTUnwrap(reference.stored))
        XCTAssertGreaterThan(referenceLayout.pairs, 0, "the recipe must leave pairs")
        XCTAssertGreaterThan(referenceLayout.unpaired, 0, "the recipe must merge some pairs")

        let trimGalore = try await importPairs(with: .trimGalore, label: "trim-galore")

        XCTAssertEqual(trimGalore.result.failed, 0, "\(trimGalore.result.errors)")
        XCTAssertEqual(trimGalore.result.completed, 1)
        let layout = try MixedStorageFASTQ.layout(of: try XCTUnwrap(trimGalore.stored))
        XCTAssertEqual(layout, referenceLayout, "the same pairs and merged reads, pairs first, as the bbtools route stores them")
    }
}
