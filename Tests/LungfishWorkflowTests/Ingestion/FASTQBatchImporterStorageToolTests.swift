// FASTQBatchImporterStorageToolTests.swift - the import refuses a storage tool before any recipe step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

private final class StepStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record(_ event: ImportLogEvent) {
        guard case .stepStart = event else { return }
        lock.withLock { count += 1 }
    }

    var stepStarts: Int { lock.withLock { count } }
}

/// The 2026-10-20 VSP2 import with Trim Galore would have failed at the
/// storage step after hours of recipe work. The batch importer now refuses
/// the combination before the first step, so a run without any tool installed
/// still fails at once and with the way out.
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

    private func writePair() throws -> SamplePair {
        let r1 = tempDir.appendingPathComponent("s_R1.fastq")
        let r2 = tempDir.appendingPathComponent("s_R2.fastq")
        try "@p1/1\nACGTACGT\n+\nIIIIIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@p1/2\nACGTACGT\n+\nIIIIIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        return SamplePair(sampleName: "s", r1: r1, r2: r2)
    }

    func testVSP2WithTrimGaloreFailsBeforeAnyRecipeStep() async throws {
        let recipe = try XCTUnwrap((try? RecipeResolver.resolve("vsp2-target-enrichment", in: RecipeRegistryV2.builtinRecipes())))
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: tempDir.appendingPathComponent("Storage.lungfish"), platform: .illumina,
            newRecipe: recipe,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: true,
            clumpingTool: .trimGalore,
            threads: 2
        )
        let counter = StepStartCounter()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [try writePair()], config: config, log: { counter.record($0) }
        )

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(counter.stepStarts, 0, "no recipe or storage step may start")
        let message = try XCTUnwrap(result.errors.first?.error)
        XCTAssertTrue(message.contains("Trim Galore"), message)
        XCTAssertTrue(message.contains("BBTools clumpify"), message)
        XCTAssertTrue(message.contains("skip storage optimization"), message)
    }
}
