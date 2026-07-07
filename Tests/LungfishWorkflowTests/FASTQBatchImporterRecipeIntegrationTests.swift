// FASTQBatchImporterRecipeIntegrationTests.swift - Real-tool coverage for importer recipe execution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO

private final class FASTQBatchImporterRecipeEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ImportLogEvent] = []

    func append(_ event: ImportLogEvent) {
        lock.withLock {
            storage.append(event)
        }
    }

    var events: [ImportLogEvent] {
        lock.withLock { storage }
    }
}

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

    func testRunBatchImportUnsupportedLegacyStepFailsBeforeProcessingPairedFASTQ() async throws {
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
        let collector = FASTQBatchImporterRecipeEventCollector()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config,
            log: { collector.append($0) }
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.errors.first?.sample, "sample")
        XCTAssertTrue(
            result.errors.first?.error.contains("unsupported step 'primerRemoval'") == true,
            "Expected unsupported-step preflight error, got \(String(describing: result.errors.first?.error))"
        )

        let bundleURL = config.projectDirectory
            .appendingPathComponent("Imports")
            .appendingPathComponent("sample.lungfishfastq")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundleURL.path),
            "Unsupported legacy recipes must not leave a partial FASTQ bundle"
        )
        XCTAssertFalse(
            collector.events.contains {
                if case .stepStart = $0 { return true }
                return false
            },
            "Unsupported legacy recipes should fail before recipe or ingestion steps start"
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
        let collector = FASTQBatchImporterRecipeEventCollector()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config,
            log: { collector.append($0) }
        )

        XCTAssertEqual(result.completed, 1, "Importer should create a bundle for paired-end merge recipes")
        XCTAssertEqual(result.failed, 0, "Importer should not fail when bbmerge reads interleaved input")
        XCTAssertTrue(result.errors.isEmpty)

        let bundleURL = config.projectDirectory
            .appendingPathComponent("Imports")
            .appendingPathComponent("merge-sample.lungfishfastq")
        let fastqURL = bundleURL.appendingPathComponent("merge-sample.fastq.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fastqURL.path),
            "Merged bundle should contain the final FASTQ payload"
        )
        let rawInputSize = try fileSize(pair.r1) + fileSize(try XCTUnwrap(pair.r2))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastqURL))
        XCTAssertEqual(metadata.ingestion?.originalSizeBytes, rawInputSize)
        XCTAssertNotNil(metadata.ingestion?.storageInputSizeBytes)
        XCTAssertEqual(metadata.ingestion?.storageOutputSizeBytes, try fileSize(fastqURL))

        let startedSteps = collector.events.compactMap { event -> (String, Int, Int)? in
            guard case .stepStart(_, let step, let stepIndex, let totalSteps) = event else {
                return nil
            }
            return (step, stepIndex, totalSteps)
        }
        XCTAssertEqual(startedSteps.map(\.0), [
            "merge-strict",
            "Compress",
            "Compute statistics",
        ])
        XCTAssertEqual(startedSteps.map(\.1), [1, 2, 3])
        XCTAssertEqual(startedSteps.map(\.2), [1, 3, 3])
    }

    func testRunBatchImportVSP2RetainsDeaconSummaryArtifactAndProvenance() async throws {
        try await requireManagedTools([.fastp, .seqkit, .deacon])
        guard let _ = await DatabaseRegistry.shared.effectiveDatabasePath(for: "deacon-panhuman") else {
            throw XCTSkip("Deacon human-read removal index not installed")
        }
        let recipe = try XCTUnwrap(
            RecipeRegistryV2.builtinRecipes().first { $0.id == "vsp2-target-enrichment" }
        )

        let sequence = String(repeating: "ACGT", count: 30)
        let quality = String(repeating: "I", count: sequence.count)
        let pair = SamplePair(
            sampleName: "vsp2",
            r1: tempDir.appendingPathComponent("vsp2_R1.fastq"),
            r2: tempDir.appendingPathComponent("vsp2_R2.fastq")
        )
        try writeFASTQ(
            to: pair.r1,
            records: [
                ("@pair1/1", sequence, quality),
                ("@pair2/1", sequence, quality),
            ]
        )
        try writeFASTQ(
            to: try XCTUnwrap(pair.r2),
            records: [
                ("@pair1/2", sequence, quality),
                ("@pair2/2", sequence, quality),
            ]
        )

        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: tempDir.appendingPathComponent("VSP2Project.lungfish"),
            newRecipe: recipe,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 2
        )
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config
        )

        XCTAssertEqual(result.completed, 1, "VSP2 import should succeed. Errors: \(result.errors)")
        XCTAssertEqual(result.failed, 0)

        let bundleURL = config.projectDirectory
            .appendingPathComponent("Imports")
            .appendingPathComponent("vsp2.lungfishfastq")
        let fastqURL = bundleURL.appendingPathComponent("vsp2.fastq.gz")
        let summaryURL = bundleURL
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("recipe-step-artifacts", isDirectory: true)
            .appendingPathComponent("2-1-remove-human-reads-vsp2_deacon_summary.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastqURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))

        let summaryData = try Data(contentsOf: summaryURL)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: summaryData) as? [String: Any])
        XCTAssertEqual(summary["deplete"] as? Bool, true)
        XCTAssertGreaterThan(summary["seqs_in"] as? Int ?? 0, 0)
        XCTAssertNotNil(summary["seqs_removed"])

        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastqURL))
        let deaconStep = try XCTUnwrap(metadata.ingestion?.recipeApplied?.stepResults.first { $0.tool == "deacon" })
        XCTAssertEqual(deaconStep.auxiliaryOutputPaths, [summaryURL.path])
        XCTAssertTrue(deaconStep.auxiliaryCommandPathRewrites.values.contains(summaryURL.path))
        XCTAssertNotNil(metadata.ingestion?.recipeApplied?.humanScrubSummary)

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        let provenanceStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "deacon" })
        let summaryOutput = try XCTUnwrap(provenanceStep.outputs.first { $0.path == summaryURL.path })
        XCTAssertNotNil(summaryOutput.checksumSHA256)
        XCTAssertEqual(summaryOutput.fileSize, UInt64(summaryData.count))
        XCTAssertTrue(provenanceStep.durableReplayArgv?.contains(summaryURL.path) == true)
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

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? Int64)
    }
}
