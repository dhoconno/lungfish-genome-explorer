// SalmonQuantImportLineConformanceTests.swift - The quant's import line on bundles a real import wrote (review RS-QUANT BIO B1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Two real `FASTQBatchImporter` runs with no recipe, one storing through Trim Galore 2.3.0 and one through the
/// compressor alone, then the import line `rnaseq quant` records for each bundle. The stand-in beside it is
/// `SalmonQuantRouteTests.testATrimGaloreImportWithNoRecipeNeverReadsNoTrimmerRan`, the default.
final class SalmonQuantImportLineConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "quant-import-line")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Imports the twelve review pairs as sample `s` with `tool` and returns the bundle.
    private func importPairs(_ tool: ClumpingTool, label: String) async throws -> URL {
        let input = root.appendingPathComponent("\(label)-input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let r1 = input.appendingPathComponent("s_R1.fastq"), r2 = input.appendingPathComponent("s_R2.fastq")
        try MixedStorageFASTQ.writeReviewPairs(r1: r1, r2: r2)
        let project = root.appendingPathComponent("\(label).lungfish", isDirectory: true)
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: "s", r1: r1, r2: r2)],
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project, platform: .given(.illumina), qualityBinning: QualityBinningScheme.none,
                optimizeStorage: tool != .none, clumpingTool: tool, threads: 2))
        XCTAssertEqual(result.completed, 1, "\(result.errors)")
        return project.appendingPathComponent("Imports/s.lungfishfastq", isDirectory: true)
    }

    func line(_ bundle: URL) -> String {
        SalmonQuantRecordLines.importPolyG(payloads: [bundle.appendingPathComponent("s.fastq.gz")], bundle: bundle)
    }

    func testARealTrimGaloreImportReadsTrimGaloreAndARealPlainImportReadsNoTrimmer() async throws {
        _ = try await ToolAvailability.require("trim_galore", environment: "trim_galore")
        _ = try await ToolAvailability.require("reformat.sh", environment: "bbtools")
        _ = try await ToolAvailability.require("bgzip", environment: "htslib")

        let galore = try await importPairs(.trimGalore, label: "trim-galore")
        XCTAssertNil(FASTQMetadataStore.load(for: galore.appendingPathComponent("s.fastq.gz"))?.ingestion?.recipeApplied,
                     "the import with no recipe saves no recipe")
        let step = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: galore)?.steps.first { $0.toolName == "trim_galore" })
        guard case .boolean(let polyG)? = step.resolvedOptions["poly_g"] else {
            return XCTFail("the record keeps the report's poly_g: \(step.resolvedOptions)")
        }
        let words = line(galore)
        XCTAssertTrue(words.hasPrefix("Poly-G trimming at import: left to Trim Galore "), words)
        XCTAssertTrue(words.hasSuffix("auto-detection (not set by LGE), " + (polyG ? "enabled (auto-detected)" : "not enabled")), words)
        XCTAssertFalse(words.contains("no trimmer ran"), words)

        let plain = try await importPairs(.none, label: "plain")
        XCTAssertEqual(line(plain), "Poly-G trimming at import: not enabled (no trimmer ran at import)")
    }
}
