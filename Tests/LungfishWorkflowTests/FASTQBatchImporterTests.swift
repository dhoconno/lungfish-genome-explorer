// FASTQBatchImporterTests.swift - Unit tests for FASTQBatchImporter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO

private final class FASTQBatchImporterEventCollector: @unchecked Sendable {
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

final class FASTQBatchImporterTests: XCTestCase {

    private static let gib: Int64 = 1_073_741_824

    // MARK: - Pair Detection

    func testPairDetectionIlluminaStandard() {
        // 4 files in standard bcl2fastq naming → 2 pairs
        let urls = makeURLs([
            "SampleA_R1_001.fastq.gz",
            "SampleA_R2_001.fastq.gz",
            "SampleB_R1_001.fastq.gz",
            "SampleB_R2_001.fastq.gz",
        ])

        let pairs = FASTQBatchImporter.detectPairs(from: urls)

        XCTAssertEqual(pairs.count, 2)
        let sampleA = pairs.first { $0.sampleName == "SampleA" }
        let sampleB = pairs.first { $0.sampleName == "SampleB" }
        XCTAssertNotNil(sampleA, "SampleA pair should be detected")
        XCTAssertNotNil(sampleB, "SampleB pair should be detected")
        XCTAssertNotNil(sampleA?.r2, "SampleA should have an R2")
        XCTAssertNotNil(sampleB?.r2, "SampleB should have an R2")
        XCTAssertTrue(sampleA?.r1.lastPathComponent.contains("R1") ?? false)
        XCTAssertTrue(sampleA?.r2?.lastPathComponent.contains("R2") ?? false)
    }

    func testPairDetectionUnpairedFile() {
        // 1 unpaired file → 1 single-end pair
        let urls = makeURLs(["MySample.fastq.gz"])

        let pairs = FASTQBatchImporter.detectPairs(from: urls)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sampleName, "MySample")
        XCTAssertNil(pairs[0].r2, "Single file should have no R2")
    }

    func testPairDetectionSimplifiedR1R2() {
        // _R1/_R2 pattern (without _001)
        let urls = makeURLs([
            "Sample_R1.fq.gz",
            "Sample_R2.fq.gz",
        ])

        let pairs = FASTQBatchImporter.detectPairs(from: urls)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sampleName, "Sample")
        XCTAssertNotNil(pairs[0].r2)
    }

    func testPairDetectionNumericSuffix() {
        // _1/_2 numeric pattern
        let urls = makeURLs([
            "Run001_1.fastq.gz",
            "Run001_2.fastq.gz",
        ])

        let pairs = FASTQBatchImporter.detectPairs(from: urls)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sampleName, "Run001")
        XCTAssertNotNil(pairs[0].r2)
    }

    func testPairDetectionFromDirectory() throws {
        // Create a temp directory with empty files, scan it
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let filenames = [
            "Alpha_R1_001.fastq.gz",
            "Alpha_R2_001.fastq.gz",
            "Beta_R1_001.fastq.gz",
            "Beta_R2_001.fastq.gz",
            "Gamma.fastq.gz",   // unpaired
        ]
        for name in filenames {
            FileManager.default.createFile(atPath: tmpDir.appendingPathComponent(name).path, contents: nil)
        }

        let pairs = try FASTQBatchImporter.detectPairsFromDirectory(tmpDir)

        XCTAssertEqual(pairs.count, 3, "Should detect 2 pairs + 1 single-end")
        let names = Set(pairs.map(\.sampleName))
        XCTAssertTrue(names.contains("Alpha"))
        XCTAssertTrue(names.contains("Beta"))
        XCTAssertTrue(names.contains("Gamma"))
        let gammaEntry = pairs.first { $0.sampleName == "Gamma" }
        XCTAssertNil(gammaEntry?.r2, "Gamma should be single-end")
    }

    func testPairDetectionFromDirectoryIncludesBAMAsSingleEndSample() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-bam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bamURL = tmpDir.appendingPathComponent("NanoporeSample.BAM")
        FileManager.default.createFile(atPath: bamURL.path, contents: Data([0x42]))

        let pairs = try FASTQBatchImporter.detectPairsFromDirectory(tmpDir)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sampleName, "NanoporeSample")
        XCTAssertEqual(pairs[0].r1.standardizedFileURL, bamURL.standardizedFileURL)
        XCTAssertNil(pairs[0].r2)
    }

    func testBAMIsRecordedAsBAMInImportProvenance() {
        XCTAssertEqual(
            FASTQBatchImporter.provenanceFormat(for: URL(fileURLWithPath: "/tmp/reads.bam")),
            .bam
        )
        XCTAssertEqual(
            FASTQBatchImporter.provenanceFormat(for: URL(fileURLWithPath: "/tmp/reads.fastq.gz")),
            .fastq
        )
    }

    func testPairDetectionFromEmptyDirectoryThrows() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        XCTAssertThrowsError(try FASTQBatchImporter.detectPairsFromDirectory(tmpDir)) { error in
            guard case BatchImportError.noFASTQFilesFound = error else {
                XCTFail("Expected noFASTQFilesFound, got \(error)")
                return
            }
        }
    }

    func testSampleSheetParsesPairedIlluminaRowsAndMetadata() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-samplesheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let r1 = tmpDir.appendingPathComponent("Alpha_R1.fastq.gz")
        let r2 = tmpDir.appendingPathComponent("Alpha_R2.fastq.gz")
        let betaR1 = tmpDir.appendingPathComponent("Beta_R1.fastq.gz")
        let betaR2 = tmpDir.appendingPathComponent("Beta_R2.fastq.gz")
        for url in [r1, r2, betaR1, betaR2] {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }

        let sheetURL = tmpDir.appendingPathComponent("samples.csv")
        try """
        sample,r1,r2,collection_date,batch_id,operator
        Alpha,Alpha_R1.fastq.gz,Alpha_R2.fastq.gz,2026-05-10,B42,Ada
        Beta,\(betaR1.path),\(betaR2.path),2026-05-11,B42,Grace
        """.write(to: sheetURL, atomically: true, encoding: .utf8)

        let parsed = try FASTQSampleSheet.parse(url: sheetURL)

        XCTAssertEqual(parsed.sourceURL.standardizedFileURL, sheetURL.standardizedFileURL)
        XCTAssertEqual(parsed.entries.count, 2)
        XCTAssertEqual(parsed.entries[0].sampleName, "Alpha")
        XCTAssertEqual(parsed.entries[0].r1.standardizedFileURL, r1.standardizedFileURL)
        XCTAssertEqual(parsed.entries[0].r2.standardizedFileURL, r2.standardizedFileURL)
        XCTAssertEqual(parsed.entries[0].metadata["collection_date"], "2026-05-10")
        XCTAssertEqual(parsed.entries[0].metadata["batch_id"], "B42")
        XCTAssertEqual(parsed.entries[0].metadata["operator"], "Ada")
        XCTAssertEqual(parsed.entries[1].sampleName, "Beta")
        XCTAssertEqual(parsed.entries[1].r1.standardizedFileURL, betaR1.standardizedFileURL)
    }

    func testSampleSheetPairsCarryMetadataAndSourceForProvenance() throws {
        let sheetURL = URL(fileURLWithPath: "/data/run/samples.csv")
        let pairs = try FASTQSampleSheet(
            sourceURL: sheetURL,
            entries: [
                FASTQSampleSheet.Entry(
                    sampleName: "Alpha",
                    r1: URL(fileURLWithPath: "/data/run/Alpha_R1.fastq.gz"),
                    r2: URL(fileURLWithPath: "/data/run/Alpha_R2.fastq.gz"),
                    metadata: ["collection_date": "2026-05-10", "batch_id": "B42"]
                )
            ]
        ).samplePairs()

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sampleName, "Alpha")
        XCTAssertEqual(pairs[0].metadata["collection_date"], "2026-05-10")
        XCTAssertEqual(pairs[0].sampleSheetURL?.standardizedFileURL, sheetURL.standardizedFileURL)
    }

    // MARK: - Recipe Resolution

    func testRecipeResolutionVSP2() throws {
        let recipe = try FASTQBatchImporter.resolveRecipe(named: "vsp2")
        XCTAssertEqual(recipe.name, ProcessingRecipe.illuminaVSP2TargetEnrichment.name)
        XCTAssertEqual(recipe.steps.count, 6, "VSP2 recipe should have 6 steps")
        // Verify step kinds in order
        XCTAssertEqual(recipe.steps[0].kind, .deduplicate)
        XCTAssertEqual(recipe.steps[1].kind, .adapterTrim)
        XCTAssertEqual(recipe.steps[2].kind, .qualityTrim)
        XCTAssertEqual(recipe.steps[3].kind, .humanReadScrub)
        XCTAssertEqual(recipe.steps[4].kind, .pairedEndMerge)
        XCTAssertEqual(recipe.steps[5].kind, .lengthFilter)
    }

    func testRecipeResolutionVSP2CaseInsensitive() throws {
        let upper = try FASTQBatchImporter.resolveRecipe(named: "VSP2")
        let lower = try FASTQBatchImporter.resolveRecipe(named: "vsp2")
        XCTAssertEqual(upper.id, lower.id)
    }

    func testRecipeResolutionWGS() throws {
        let recipe = try FASTQBatchImporter.resolveRecipe(named: "wgs")
        XCTAssertEqual(recipe.name, ProcessingRecipe.illuminaWGS.name)
        XCTAssertEqual(recipe.steps.count, 3)
    }

    func testRecipeResolutionAmpliconIsRejectedUntilPrimerRemovalIsExecutable() {
        XCTAssertThrowsError(try FASTQBatchImporter.resolveRecipe(named: "amplicon")) { error in
            guard case BatchImportError.unsupportedRecipe(let name, let reason) = error else {
                XCTFail("Expected unsupportedRecipe, got \(error)")
                return
            }
            XCTAssertEqual(name, "amplicon")
            XCTAssertTrue(reason.contains("primer removal"), reason)
        }
    }

    func testRecipeResolutionHiFi() throws {
        let recipe = try FASTQBatchImporter.resolveRecipe(named: "hifi")
        XCTAssertEqual(recipe.name, ProcessingRecipe.pacbioHiFi.name)
    }

    func testRecipeResolutionUnknown() {
        XCTAssertThrowsError(try FASTQBatchImporter.resolveRecipe(named: "bogus")) { error in
            guard case BatchImportError.unknownRecipe(let name) = error else {
                XCTFail("Expected unknownRecipe, got \(error)")
                return
            }
            XCTAssertEqual(name, "bogus")
        }
    }

    func testRecipeResolutionNoneThrows() {
        // "none" is not a valid name — callers pass nil recipe in ImportConfig instead
        XCTAssertThrowsError(try FASTQBatchImporter.resolveRecipe(named: "none"))
    }

    // MARK: - Skip Logic

    func testSkipExistingBundles() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try makeCompleteImportedFASTQBundle(projectURL: tmpDir, sampleName: "SampleX")

        let pair = SamplePair(sampleName: "SampleX", r1: URL(fileURLWithPath: "/tmp/x_R1.fastq.gz"), r2: nil)
        XCTAssertTrue(FASTQBatchImporter.bundleExists(for: pair, in: tmpDir), "Should detect existing bundle")
    }

    func testIncompleteBundleDoesNotBlockRetry() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-incomplete-\(UUID().uuidString)")
        let bundleURL = tmpDir
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("SampleX.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: bundleURL.appendingPathComponent("SampleX.fastq.gz"))
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pair = SamplePair(sampleName: "SampleX", r1: URL(fileURLWithPath: "/tmp/x_R1.fastq.gz"), r2: nil)
        XCTAssertFalse(FASTQBatchImporter.bundleExists(for: pair, in: tmpDir))
    }

    func testBundleWithRootOnlyProvenanceDoesNotBlockRetry() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-root-only-provenance-\(UUID().uuidString)")
        let bundleURL = tmpDir
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("SampleX.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fastqURL = bundleURL.appendingPathComponent("SampleX.fastq.gz")
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: fastqURL)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .singleEnd)),
            for: fastqURL
        )

        let rootOnlyEnvelope = ProvenanceEnvelope.fixture(
            workflowName: "lungfish import fastq",
            toolName: "lungfish import fastq",
            outputPath: fastqURL.path
        )
        try ProvenanceJSON.encoder.encode(rootOnlyEnvelope)
            .write(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))

        let pair = SamplePair(sampleName: "SampleX", r1: URL(fileURLWithPath: "/tmp/x_R1.fastq.gz"), r2: nil)
        XCTAssertFalse(FASTQBatchImporter.bundleExists(for: pair, in: tmpDir))
    }

    func testBundleWithStaleFocusedProvenanceDoesNotBlockRetry() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-stale-provenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bundleURL = try makeCompleteImportedFASTQBundle(projectURL: tmpDir, sampleName: "SampleX")
        try Data("@r\nTTTT\n+\nIIII\n".utf8).write(to: bundleURL.appendingPathComponent("SampleX.fastq.gz"))

        let pair = SamplePair(sampleName: "SampleX", r1: URL(fileURLWithPath: "/tmp/x_R1.fastq.gz"), r2: nil)
        XCTAssertFalse(FASTQBatchImporter.bundleExists(for: pair, in: tmpDir))
    }

    func testRequiredSeqkitStatsRejectsIncompleteOutput() {
        XCTAssertThrowsError(
            try FASTQBatchImporter.parseRequiredSeqkitStats(stdout: "file\tformat\nsample.fastq\tFASTQ\n")
        )
    }

    func testBundleDoesNotExist() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-noexist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pair = SamplePair(sampleName: "NoSuchSample", r1: URL(fileURLWithPath: "/tmp/x.fastq.gz"), r2: nil)
        XCTAssertFalse(FASTQBatchImporter.bundleExists(for: pair, in: tmpDir))
    }

    // MARK: - Structured Logging

    func testLogEventJSONEncodingSampleComplete() {
        let event = ImportLogEvent.sampleComplete(
            sample: "TestSample",
            bundle: "TestSample.lungfishfastq",
            durationSeconds: 42.5,
            originalBytes: 1_000_000,
            finalBytes: 500_000
        )
        let json = FASTQBatchImporter.encodeLogEvent(event)

        XCTAssertTrue(json.hasPrefix("{"), "Should be a JSON object")
        XCTAssertTrue(json.contains("\"sampleComplete\""), "Should contain event type")
        XCTAssertTrue(json.contains("\"TestSample\""), "Should contain sample name")
        XCTAssertTrue(json.contains("42.5") || json.contains("42"), "Should contain duration")
        XCTAssertTrue(json.contains("1000000"), "Should contain original bytes")
        XCTAssertTrue(json.contains("500000"), "Should contain final bytes")
        XCTAssertTrue(json.contains("timestamp"), "Should contain timestamp")

        // Verify parseable as JSON
        let data = json.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    func testLogEventImportStart() {
        let event = ImportLogEvent.importStart(sampleCount: 10, recipeName: "Illumina VSP2")
        let json = FASTQBatchImporter.encodeLogEvent(event)

        XCTAssertTrue(json.contains("\"importStart\""))
        XCTAssertTrue(json.contains("10"))
        XCTAssertTrue(json.contains("Illumina VSP2"))

        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["event"] as? String, "importStart")
        XCTAssertEqual(parsed?["sampleCount"] as? Int, 10)
        XCTAssertEqual(parsed?["recipeName"] as? String, "Illumina VSP2")
    }

    func testLogEventImportStartNoRecipe() {
        let event = ImportLogEvent.importStart(sampleCount: 3, recipeName: nil)
        let json = FASTQBatchImporter.encodeLogEvent(event)

        XCTAssertTrue(json.contains("\"importStart\""))
        // recipeName key should be absent when nil
        XCTAssertFalse(json.contains("recipeName"))
    }

    func testLogEventNoticeJSONEncoding() throws {
        let event = ImportLogEvent.notice(
            sample: "Sample1",
            message: "Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads."
        )
        let json = FASTQBatchImporter.encodeLogEvent(event)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["event"] as? String, "notice")
        XCTAssertEqual(parsed["sample"] as? String, "Sample1")
        XCTAssertEqual(
            parsed["message"] as? String,
            "Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads."
        )
    }

    func testIngestionNoticeAndResultUseTheSameClumpingResolution() async throws {
        final class InvocationRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [String] = []

            func append(_ entry: String) {
                lock.withLock { entries.append(entry) }
            }

            var snapshot: [String] {
                lock.withLock { entries }
            }
        }

        let baseConfig = FASTQIngestionConfig(
            inputFiles: [URL(fileURLWithPath: "/data/Sample.fastq.gz")],
            outputDirectory: URL(fileURLWithPath: "/tmp/import-workspace")
        )
        let expectedMessage = "Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads."
        let cases: [(requested: ClumpingTool, inputBytes: Int64, memoryBytes: Int64, resolved: ClumpingTool)] = [
            (.trimGalore, 1 * Self.gib, 64 * Self.gib, .trimGalore),
            (.auto, 20 * Self.gib, 64 * Self.gib, .trimGalore),
            (.bbtools, 20 * Self.gib, 64 * Self.gib, .bbtools),
            (.none, 20 * Self.gib, 64 * Self.gib, .none),
            (.auto, 1 * Self.gib, 64 * Self.gib, .bbtools),
        ]

        for testCase in cases {
            let recorder = InvocationRecorder()
            let toolConfig = FASTQIngestionConfig(
                inputFiles: baseConfig.inputFiles,
                outputDirectory: baseConfig.outputDirectory,
                clumpingTool: testCase.requested
            )
            let result = try await FASTQBatchImporter.runIngestionPipeline(
                sample: "Sample1",
                config: toolConfig,
                estimatedInputBytes: testCase.inputBytes,
                physicalMemoryBytes: testCase.memoryBytes,
                log: { event in
                    if case let .notice(sample, message) = event {
                        recorder.append("notice:\(sample):\(message)")
                    }
                },
                invoke: { resolution in
                    recorder.append("pipeline:\(resolution.resolved.rawValue)")
                    return FASTQIngestionResult(
                        outputFile: URL(fileURLWithPath: "/tmp/output.fastq.gz"),
                        wasClumpified: resolution.resolved != .none,
                        qualityBinning: .illumina4,
                        originalFilenames: ["Sample.fastq.gz"],
                        originalSizeBytes: testCase.inputBytes,
                        finalSizeBytes: 1,
                        pairingMode: .singleEnd,
                        requestedClumpingTool: resolution.requested,
                        resolvedClumpingTool: resolution.resolved,
                        clumpingResolution: resolution
                    )
                }
            )

            let pipelineEntry = "pipeline:\(testCase.resolved.rawValue)"
            let expectedEntries = testCase.resolved == .trimGalore
                ? ["notice:Sample1:\(expectedMessage)", pipelineEntry]
                : [pipelineEntry]
            XCTAssertEqual(recorder.snapshot, expectedEntries, "Unexpected ordering for \(testCase.requested)")
            XCTAssertEqual(result.requestedClumpingTool, testCase.requested)
            XCTAssertEqual(result.resolvedClumpingTool, testCase.resolved)
            XCTAssertEqual(result.clumpingResolution.requested, testCase.requested)
            XCTAssertEqual(result.clumpingResolution.resolved, testCase.resolved)
        }
    }

    func testLogEventSampleSkip() {
        let event = ImportLogEvent.sampleSkip(sample: "S1", reason: "Bundle already exists")
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("\"sampleSkip\""))
        XCTAssertTrue(json.contains("Bundle already exists"))
    }

    func testLogEventSampleFailed() {
        let event = ImportLogEvent.sampleFailed(sample: "Bad", error: "Tool not found")
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("\"sampleFailed\""))
        XCTAssertTrue(json.contains("Tool not found"))
    }

    func testLogEventImportComplete() {
        let event = ImportLogEvent.importComplete(
            completed: 8, skipped: 2, failed: 1, totalDurationSeconds: 300.0
        )
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("\"importComplete\""))
        XCTAssertTrue(json.contains("\"completed\""))
        XCTAssertTrue(json.contains("\"skipped\""))
        XCTAssertTrue(json.contains("\"failed\""))
    }

    func testRecipeReadDeltaEventsEmitDeduplicationAndHumanScrubSummaries() throws {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "Illumina VSP2 Target Enrichment",
            appliedDate: Date(timeIntervalSince1970: 0),
            stepResults: [
                RecipeStepResult(
                    stepName: "Remove PCR duplicates",
                    tool: "fastp",
                    inputReadCount: 1_000,
                    outputReadCount: 720,
                    durationSeconds: 1
                ),
                RecipeStepResult(
                    stepName: "Remove human reads",
                    tool: "deacon",
                    inputReadCount: 720,
                    outputReadCount: 700,
                    durationSeconds: 1
                ),
            ]
        )

        let events = FASTQBatchImporter.recipeReadDeltaEvents(sample: "S1", recipeApplied: info)

        XCTAssertEqual(events.count, 2)
        guard case let .recipeReadDelta(sample, label, inputReads, outputReads, readsRemoved, percentRemoved) = events[0] else {
            return XCTFail("Expected first read-delta event")
        }
        XCTAssertEqual(sample, "S1")
        XCTAssertEqual(label, "Deduplication")
        XCTAssertEqual(inputReads, 1_000)
        XCTAssertEqual(outputReads, 720)
        XCTAssertEqual(readsRemoved, 280)
        XCTAssertEqual(percentRemoved, 28.0, accuracy: 0.001)

        let json = FASTQBatchImporter.encodeLogEvent(events[0])
        XCTAssertTrue(json.contains("\"recipeReadDelta\""))
        XCTAssertTrue(json.contains("\"inputReads\":1000"))
        XCTAssertTrue(json.contains("\"readsRemoved\":280"))
    }

    // MARK: - ImportConfig Construction

    func testImportConfigConstruction() {
        let projectURL = URL(fileURLWithPath: "/tmp/MyProject.lungfish")
        let logURL = URL(fileURLWithPath: "/tmp/logs")
        let recipe = ProcessingRecipe.illuminaWGS

        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL,
            recipe: recipe,
            qualityBinning: .eightLevel,
            threads: 8,
            logDirectory: logURL
        )

        XCTAssertEqual(config.projectDirectory, projectURL)
        XCTAssertEqual(config.recipe?.name, recipe.name)
        XCTAssertEqual(config.qualityBinning, .eightLevel)
        XCTAssertEqual(config.threads, 8)
        XCTAssertEqual(config.logDirectory, logURL)
    }

    func testImportConfigDefaultValues() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp"),
            recipe: nil
        )
        XCTAssertNil(config.recipe)
        XCTAssertEqual(config.qualityBinning, .illumina4, "Default binning should be illumina4")
        XCTAssertEqual(config.threads, 4, "Default threads should be 4")
        XCTAssertNil(config.logDirectory)
    }

    // MARK: - SamplePair

    func testSamplePairInit() {
        let r1 = URL(fileURLWithPath: "/data/s1_R1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/s1_R2.fastq.gz")
        let pair = SamplePair(sampleName: "s1", r1: r1, r2: r2)
        XCTAssertEqual(pair.sampleName, "s1")
        XCTAssertEqual(pair.r1, r1)
        XCTAssertEqual(pair.r2, r2)
    }

    func testSamplePairSingleEnd() {
        let r1 = URL(fileURLWithPath: "/data/s1.fastq.gz")
        let pair = SamplePair(sampleName: "s1", r1: r1, r2: nil)
        XCTAssertNil(pair.r2)
    }

    // MARK: - runBatchImport (fast path — skips all samples)

    func testRunBatchImportSkipsAllExistingBundles() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pre-create bundles for all samples so they should all be skipped
        let sampleNames = ["Alpha", "Beta", "Gamma"]
        for name in sampleNames {
            try makeCompleteImportedFASTQBundle(projectURL: tmpDir, sampleName: name)
        }

        let pairs = sampleNames.map { name in
            SamplePair(sampleName: name, r1: URL(fileURLWithPath: "/dev/null"), r2: nil)
        }

        let config = FASTQBatchImporter.ImportConfig(projectDirectory: tmpDir, recipe: nil)

        // Collect skip events using a Sendable-safe approach
        actor EventCollector {
            var events: [ImportLogEvent] = []
            func add(_ e: ImportLogEvent) { events.append(e) }
        }
        let collector = EventCollector()

        let result = await FASTQBatchImporter.runBatchImport(pairs: pairs, config: config) { event in
            Task { await collector.add(event) }
        }

        XCTAssertEqual(result.skipped, 3)
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.errors.isEmpty)

        // Give actor tasks a moment to flush
        try await Task.sleep(nanoseconds: 10_000_000)
        let logEvents = await collector.events
        let skipEvents = logEvents.compactMap { event -> String? in
            if case .sampleSkip(let sample, _) = event { return sample } else { return nil }
        }
        XCTAssertEqual(Set(skipEvents), Set(sampleNames))
    }

    func testRunBatchImportEmptyPairsReturnsZeros() async {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/tmp"),
            recipe: nil
        )
        let result = await FASTQBatchImporter.runBatchImport(pairs: [], config: config, log: nil)
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testRunBatchImportNoOptimizePreservesPairedSourceFiles() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-source-preserve-\(UUID().uuidString)")
        let sourceDir = tmpDir.appendingPathComponent("source", isDirectory: true)
        let projectURL = tmpDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let r1 = sourceDir.appendingPathComponent("Sample_R1.fastq.gz")
        let r2 = sourceDir.appendingPathComponent("Sample_R2.fastq.gz")
        let r1Contents = "@read1/1\nACGT\n+\nIIII\n"
        let r2Contents = "@read1/2\nTGCA\n+\nIIII\n"
        try r1Contents.write(to: r1, atomically: true, encoding: .utf8)
        try r2Contents.write(to: r2, atomically: true, encoding: .utf8)

        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL,
            recipe: nil,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1
        )
        let pair = SamplePair(sampleName: "Sample", r1: r1, r2: r2)

        let result = await FASTQBatchImporter.runBatchImport(pairs: [pair], config: config, log: nil)

        XCTAssertEqual(result.completed, 1, "Import should succeed. Errors: \(result.errors)")
        XCTAssertEqual(try String(contentsOf: r1, encoding: .utf8), r1Contents)
        XCTAssertEqual(try String(contentsOf: r2, encoding: .utf8), r2Contents)
        let bundleURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
            )
        )
        let bundleFASTQURL = bundleURL.appendingPathComponent("Sample.fastq.gz")
        let provenanceData = try Data(
            contentsOf: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        )
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: provenanceData)
        let legacyRun = try ProvenanceJSON.decoder.decode(WorkflowRun.self, from: provenanceData)
        XCTAssertEqual(legacyRun.name, "lungfish import fastq")
        XCTAssertEqual(legacyRun.status, .completed)
        XCTAssertEqual(envelope.workflowName, "lungfish import fastq")
        XCTAssertEqual(envelope.toolName, "lungfish import fastq")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(
            envelope.options.defaults["platform"],
            .string(LungfishWorkflow.SequencingPlatform.illumina.rawValue)
        )
        XCTAssertEqual(envelope.options.defaults["threads"], .integer(4))
        XCTAssertEqual(envelope.options.defaults["optimizeStorage"], .boolean(true))
        XCTAssertEqual(envelope.options.resolvedDefaults["threads"], .integer(1))
        XCTAssertEqual(envelope.options.resolvedDefaults["qualityBinning"], .string(QualityBinningScheme.none.rawValue))
        XCTAssertEqual(envelope.options.resolvedDefaults["optimizeStorage"], .boolean(false))
        XCTAssertEqual(envelope.options.resolvedDefaults["primaryFASTQ"], .file(bundleFASTQURL))
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "lungfish import fastq" })
        XCTAssertTrue(envelope.outputs.contains {
            $0.path == bundleFASTQURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        let descriptorPaths = envelope.files.map(\.path)
            + envelope.outputs.map(\.path)
            + envelope.steps.flatMap { $0.inputs.map(\.path) + $0.outputs.map(\.path) }
        XCTAssertFalse(
            descriptorPaths.contains { $0.contains("/.tmp/") || $0.contains(".building-") },
            "Final provenance descriptors should point at bundle payloads, not temp or hidden staging files"
        )
        let replayFields = (envelope.durableReplayArgv ?? [])
            + [envelope.reproducibleCommand]
            + envelope.steps.flatMap { step in
                (step.durableReplayArgv ?? []) + [step.reproducibleCommand]
            }
        XCTAssertFalse(
            replayFields.contains { $0.contains("/.tmp/") || $0.contains(".building-") },
            "Replay provenance should point at final bundle payloads, not temp or hidden staging files"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL
                    .appendingPathComponent("provenance", isDirectory: true)
                    .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                    .path
            )
        )
        let focusedSidecarURL = try XCTUnwrap(
            ProvenanceWriter.bundleOutputSidecarURL(for: bundleFASTQURL, inBundle: bundleURL)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: focusedSidecarURL.path))
        let focusedEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: focusedSidecarURL)
        )
        XCTAssertEqual(focusedEnvelope.output?.path, bundleFASTQURL.path)
        XCTAssertFalse(
            focusedEnvelope.outputs.map(\.path).contains { $0.contains(".building-") || $0.contains("/.tmp/") }
        )
        let focusedReplayFields = (focusedEnvelope.durableReplayArgv ?? [])
            + [focusedEnvelope.reproducibleCommand]
            + focusedEnvelope.steps.flatMap { step in
                (step.durableReplayArgv ?? []) + [step.reproducibleCommand]
            }
        XCTAssertFalse(
            focusedReplayFields.contains { $0.contains("/.tmp/") || $0.contains(".building-") },
            "Focused replay provenance should point at final bundle payloads, not temp or hidden staging files"
        )
    }

    func testRunBatchImportFailsPairedOnlyRecipeBeforeStartingStepsForSingleEndSample() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-pairing-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let r1 = tmpDir.appendingPathComponent("Solo_R1.fastq")
        try """
        @read1/1
        ACGTACGT
        +
        IIIIIIII
        """.appending("\n").write(to: r1, atomically: true, encoding: .utf8)

        let recipe = Recipe(
            id: "merge-only",
            name: "Merge Only",
            requiredInput: .paired,
            steps: [
                RecipeStep(type: "fastp-merge", label: "Merge overlapping pairs", params: nil),
            ]
        )
        let projectURL = tmpDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL,
            newRecipe: recipe,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1
        )
        let pair = SamplePair(sampleName: "Solo", r1: r1, r2: nil)
        let collector = FASTQBatchImporterEventCollector()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config,
            log: { collector.append($0) }
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.errors.first?.sample, "Solo")
        XCTAssertTrue(
            result.errors.first?.error.contains("requires paired-end reads") == true,
            "Expected a readable pairing preflight error, got \(String(describing: result.errors.first?.error))"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL
                    .appendingPathComponent("Imports/Solo.\(FASTQBundle.directoryExtension)", isDirectory: true)
                    .path
            ),
            "Inapplicable recipes must not leave a partial FASTQ bundle"
        )
        XCTAssertFalse(
            collector.events.contains {
                if case .stepStart = $0 { return true }
                return false
            },
            "Importer should fail during preflight before starting recipe or ingestion steps"
        )
    }

    func testRunBatchImportFailsLegacyPairedRecipeBeforeStartingStepsForSingleEndSample() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-legacy-pairing-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let r1 = tmpDir.appendingPathComponent("LegacySolo_R1.fastq")
        try """
        @read1/1
        ACGTACGT
        +
        IIIIIIII
        """.appending("\n").write(to: r1, atomically: true, encoding: .utf8)

        let projectURL = tmpDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL,
            recipe: .illuminaWGS,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1
        )
        let pair = SamplePair(sampleName: "LegacySolo", r1: r1, r2: nil)
        let collector = FASTQBatchImporterEventCollector()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config,
            log: { collector.append($0) }
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.errors.first?.sample, "LegacySolo")
        XCTAssertTrue(
            result.errors.first?.error.contains("requires paired-end reads") == true,
            "Expected a readable pairing preflight error, got \(String(describing: result.errors.first?.error))"
        )
        XCTAssertFalse(
            collector.events.contains {
                if case .stepStart = $0 { return true }
                return false
            },
            "Legacy recipes should fail during preflight before starting recipe or ingestion steps"
        )
    }

    func testRunBatchImportFailsLegacyRecipeWithUnsupportedStepBeforeStartingSteps() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterTests-legacy-unsupported-step-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let r1 = tmpDir.appendingPathComponent("Amplicon_R1.fastq")
        let r2 = tmpDir.appendingPathComponent("Amplicon_R2.fastq")
        try """
        @read1/1
        ACGTACGT
        +
        IIIIIIII
        """.appending("\n").write(to: r1, atomically: true, encoding: .utf8)
        try """
        @read1/2
        TGCATGCA
        +
        IIIIIIII
        """.appending("\n").write(to: r2, atomically: true, encoding: .utf8)

        let recipe = ProcessingRecipe(
            name: "Primer Then Quality",
            steps: [
                FASTQDerivativeOperation(kind: .primerRemoval, createdAt: .distantPast),
                FASTQDerivativeOperation(kind: .qualityTrim, createdAt: .distantPast),
            ]
        )
        let projectURL = tmpDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL,
            recipe: recipe,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1
        )
        let pair = SamplePair(sampleName: "Amplicon", r1: r1, r2: r2)
        let collector = FASTQBatchImporterEventCollector()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [pair],
            config: config,
            log: { collector.append($0) }
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.errors.first?.sample, "Amplicon")
        XCTAssertTrue(
            result.errors.first?.error.contains("unsupported step 'primerRemoval'") == true,
            "Expected unsupported-step preflight error, got \(String(describing: result.errors.first?.error))"
        )
        XCTAssertFalse(
            collector.events.contains {
                if case .stepStart = $0 { return true }
                return false
            },
            "Unsupported legacy recipes should fail during preflight before starting recipe or ingestion steps"
        )
    }

    func testRecipeProvenancePrefersStructuredArgumentsOverQuotedCommandLine() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/input with spaces/Sample_R1.fastq")
        let outputURL = URL(fileURLWithPath: "/tmp/project/Imports/Sample.lungfishfastq/Sample.fastq.gz")
        let stepResult = RecipeStepResult(
            stepName: "Adapter trim",
            tool: "fastp",
            toolVersion: "1.0",
            commandLine: "fastp --in1 '/tmp/input with spaces/Sample_R1.fastq'",
            commandArguments: ["fastp", "--in1", inputURL.path],
            durationSeconds: 1.25
        )

        let steps = FASTQBatchImporter.recipeProvenanceSteps(
            recipeStepResults: [stepResult],
            originalInputURLs: [inputURL],
            bundleFASTQURL: outputURL
        )

        let step = try XCTUnwrap(steps.first)
        XCTAssertEqual(step.command, ["fastp", "--in1", inputURL.path])
    }

    func testRecipeProvenanceParsesQuotedCommandLineWhenStructuredArgumentsAreMissing() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/input with spaces/Sample_R1.fastq")
        let outputURL = URL(fileURLWithPath: "/tmp/project/Imports/Sample.lungfishfastq/Sample.fastq.gz")
        let stepResult = RecipeStepResult(
            stepName: "Adapter trim",
            tool: "fastp",
            toolVersion: "1.0",
            commandLine: "fastp --in1 '\(inputURL.path)' --label \"sample one\"",
            durationSeconds: 1.25
        )

        let steps = FASTQBatchImporter.recipeProvenanceSteps(
            recipeStepResults: [stepResult],
            originalInputURLs: [inputURL],
            bundleFASTQURL: outputURL
        )

        let step = try XCTUnwrap(steps.first)
        XCTAssertEqual(step.command, ["fastp", "--in1", inputURL.path, "--label", "sample one"])
    }

    func testRecipeProvenanceIncludesAuxiliaryOutputsWithDurableReplayPaths() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/input/Sample_R1.fastq")
        let bundleFASTQURL = URL(fileURLWithPath: "/tmp/project/Imports/Sample.lungfishfastq/Sample.fastq.gz")
        let temporarySummaryPath = "/tmp/project/.tmp/fastq-import-123/Sample_deacon_summary.json"
        let finalSummaryURL = URL(
            fileURLWithPath: "/tmp/project/Imports/Sample.lungfishfastq/metadata/recipe-step-artifacts/1-1-human-read-removal-Sample_deacon_summary.json"
        )
        let stepResult = RecipeStepResult(
            stepName: "Human Read Removal",
            tool: "deacon",
            toolVersion: "0.15.0",
            commandArguments: [
                "deacon", "filter", "--deplete",
                "--summary", temporarySummaryPath,
                "/tmp/db/panhuman.idx", inputURL.path,
                "-o", "/tmp/project/.tmp/fastq-import-123/Sample_scrubbed_R1.fq.gz",
            ],
            durationSeconds: 1.25,
            auxiliaryOutputPaths: [finalSummaryURL.path],
            auxiliaryCommandPathRewrites: [temporarySummaryPath: finalSummaryURL.path]
        )

        let steps = FASTQBatchImporter.recipeProvenanceSteps(
            recipeStepResults: [stepResult],
            originalInputURLs: [inputURL],
            bundleFASTQURL: bundleFASTQURL
        )

        let step = try XCTUnwrap(steps.first)
        XCTAssertTrue(step.outputs.contains { $0.path == bundleFASTQURL.path })
        XCTAssertTrue(step.outputs.contains { $0.path == finalSummaryURL.path })
        XCTAssertEqual(
            step.durableReplayArgv,
            [
                "deacon", "filter", "--deplete",
                "--summary", finalSummaryURL.path,
                "/tmp/db/panhuman.idx", inputURL.path,
                "-o", "/tmp/project/.tmp/fastq-import-123/Sample_scrubbed_R1.fq.gz",
            ]
        )
    }

    func testRecipeProvenanceRetainsFusedFastpExecutionEvidenceAndLogicalComponents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterFusedFastp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingBundleURL = root.appendingPathComponent("staging/Sample.lungfishfastq", isDirectory: true)
        let publishedBundleURL = root.appendingPathComponent("published/Sample.lungfishfastq", isDirectory: true)
        let artifactDirectory = stagingBundleURL
            .appendingPathComponent("metadata/recipe-step-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let stagedReportURL = artifactDirectory.appendingPathComponent("sample_fused_fastp_report.json")
        let reportData = Data("{\"summary\":{}}\n".utf8)
        try reportData.write(to: stagedReportURL)

        let inputURL = root.appendingPathComponent("Sample_R1.fastq")
        try Data("@read\nACGT\n+\nIIII\n".utf8).write(to: inputURL)
        let bundleFASTQURL = publishedBundleURL.appendingPathComponent("Sample.fastq.gz")
        let publishedReportURL = publishedBundleURL
            .appendingPathComponent("metadata/recipe-step-artifacts/sample_fused_fastp_report.json")
        let ephemeralR1 = root.appendingPathComponent("workspace/Sample_fused_R1.fq.gz")
        let ephemeralR2 = root.appendingPathComponent("workspace/Sample_fused_R2.fq.gz")
        let fastpExecutable = root.appendingPathComponent("conda/envs/fastp/bin/fastp")
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let completedAt = Date(timeIntervalSince1970: 1_005)
        let result = RecipeStepResult(
            stepName: "Remove PCR duplicates + Adapter + quality trim",
            tool: "fastp",
            toolVersion: "1.2.3",
            commandArguments: [fastpExecutable.path, "-j", stagedReportURL.path, "-h", "/dev/null"],
            durationSeconds: 1,
            auxiliaryOutputPaths: [publishedReportURL.path],
            auxiliaryCommandPathRewrites: [stagedReportURL.path: publishedReportURL.path],
            logicalComponents: [
                RecipeLogicalComponent(typeID: "fastp-dedup", displayName: "PCR Duplicate Removal"),
                RecipeLogicalComponent(typeID: "fastp-trim", displayName: "Adapter + Quality Trim"),
            ],
            executionOutputFiles: [
                RecipeStepOutputFile(
                    path: ephemeralR1.path,
                    checksumSHA256: "r1-sha256",
                    sizeBytes: 101
                ),
                RecipeStepOutputFile(
                    path: ephemeralR2.path,
                    checksumSHA256: "r2-sha256",
                    sizeBytes: 202
                ),
            ],
            exitStatus: 17,
            stderr: "fastp stderr output",
            startedAt: startedAt,
            completedAt: completedAt
        )

        let steps = FASTQBatchImporter.recipeProvenanceSteps(
            recipeStepResults: [result],
            originalInputURLs: [inputURL],
            bundleFASTQURL: bundleFASTQURL,
            stagingBundleURL: stagingBundleURL,
            publishedBundleURL: publishedBundleURL
        )
        let envelope = WorkflowRun(
            name: "Test fused fastp provenance",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            steps: steps
        ).canonicalEnvelope()

        let step = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(step.exitStatus, 17)
        XCTAssertEqual(step.stderr, "fastp stderr output")
        XCTAssertEqual(step.startedAt, startedAt)
        XCTAssertEqual(step.completedAt, completedAt)
        XCTAssertEqual(step.wallTimeSeconds, 5)
        XCTAssertFalse(step.outputs.contains { $0.path == bundleFASTQURL.path })
        XCTAssertEqual(
            step.outputs.filter { $0.format == .fastq }.map(\.path),
            [ephemeralR1.path, ephemeralR2.path]
        )
        XCTAssertEqual(step.outputs.first { $0.path == ephemeralR1.path }?.checksumSHA256, "r1-sha256")
        XCTAssertEqual(step.outputs.first { $0.path == ephemeralR1.path }?.fileSize, 101)
        XCTAssertEqual(step.runtimeIdentity?.executablePath, fastpExecutable.path)
        XCTAssertEqual(step.runtimeIdentity?.condaEnvironment, "fastp")
        XCTAssertEqual(step.runtimeIdentity?.condaPrefix, root.appendingPathComponent("conda/envs/fastp").path)
        XCTAssertEqual(
            step.resolvedOptions["recipeLogicalComponents"],
            .array([
                .dictionary([
                    "typeID": .string("fastp-dedup"),
                    "displayName": .string("PCR Duplicate Removal"),
                ]),
                .dictionary([
                    "typeID": .string("fastp-trim"),
                    "displayName": .string("Adapter + Quality Trim"),
                ]),
            ])
        )
        XCTAssertEqual(
            step.durableReplayArgv,
            [fastpExecutable.path, "-j", publishedReportURL.path, "-h", "/dev/null"]
        )
        let report = try XCTUnwrap(step.outputs.first { $0.path == publishedReportURL.path })
        XCTAssertNotNil(report.checksumSHA256)
        XCTAssertEqual(report.fileSize, UInt64(reportData.count))
    }

    func testLegacyStepExecutionDecodesWithoutNewOptionalEvidence() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "toolName": "fastp",
          "toolVersion": "0.23.4",
          "command": ["fastp", "--dedup"],
          "inputs": [],
          "outputs": [],
          "dependsOn": [],
          "startTime": 0
        }
        """

        let decoded = try JSONDecoder().decode(StepExecution.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(decoded.resolvedOptions)
        XCTAssertNil(decoded.runtimeIdentity)
    }

    func testRehydratedIngestionStepsPreserveRuntimeIdentity() throws {
        let sourceOutputURL = URL(fileURLWithPath: "/tmp/import-staging/sample.fastq.gz")
        let finalOutputURL = URL(fileURLWithPath: "/project/sample.lungfishfastq/sample.fastq.gz")
        let runtimeIdentity = ProvenanceRuntimeIdentity(
            appVersion: "1.2.3",
            executablePath: "/managed/conda/envs/pigz/bin/pigz",
            processIdentifier: 42,
            operatingSystemVersion: "macOS test",
            architecture: "arm64",
            user: "tester",
            condaEnvironment: "pigz",
            condaPrefix: "/managed/conda/envs/pigz"
        )
        let step = StepExecution(
            toolName: "pigz",
            toolVersion: "2.8",
            command: ["/managed/conda/envs/pigz/bin/pigz", sourceOutputURL.path],
            runtimeIdentity: runtimeIdentity,
            inputs: [],
            outputs: [FileRecord(path: sourceOutputURL.path, format: .fastq, role: .output)]
        )

        let rehydrated = FASTQBatchImporter.rehydratedIngestionSteps(
            [step],
            sourceOutputURL: sourceOutputURL,
            finalOutputURL: finalOutputURL,
            originalInputURLs: []
        )

        XCTAssertEqual(try XCTUnwrap(rehydrated.first).runtimeIdentity, runtimeIdentity)
        XCTAssertEqual(rehydrated.first?.outputs.map(\.path), [finalOutputURL.path])
    }

    func testPublishFASTQBundleUsesFoundationReplacementForExistingBundle() throws {
        let source = try String(contentsOf: fastqBatchImporterSourceURL(), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static func publishFASTQBundle"))
        let end = try XCTUnwrap(source.range(of: "\n    // MARK: - Structured Logging", range: start.upperBound..<source.endIndex))
        let method = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(method.contains("replaceItemAt"))
        XCTAssertFalse(method.contains("moveItem(at: publishedBundleURL, to:"))
    }

    // MARK: - Helpers

    private func fastqBatchImporterSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift")
    }

    @discardableResult
    private func makeCompleteImportedFASTQBundle(projectURL: URL, sampleName: String) throws -> URL {
        let bundleURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("\(sampleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastqURL = bundleURL.appendingPathComponent("\(sampleName).fastq.gz")
        try Data("@read1\nACGT\n+\nIIII\n".utf8).write(to: fastqURL)

        FASTQMetadataStore.save(
            completeFASTQMetadata(),
            for: fastqURL
        )

        try ProvenanceWriter(signingProvider: nil).write(
            realFASTQImportEnvelope(outputURL: fastqURL),
            to: bundleURL
        )

        return bundleURL
    }

    private func completeFASTQMetadata() -> PersistedFASTQMetadata {
        let stats = FASTQDatasetStatistics(
            readCount: 1,
            baseCount: 4,
            meanReadLength: 4,
            minReadLength: 4,
            maxReadLength: 4,
            medianReadLength: 4,
            n50ReadLength: 4,
            meanQuality: 40,
            q20Percentage: 100,
            q30Percentage: 100,
            gcContent: 0.5,
            readLengthHistogram: [4: 1],
            qualityScoreHistogram: [40: 4],
            perPositionQuality: []
        )
        let seqkitStats = SeqkitStatsMetadata(
            numSeqs: 1,
            sumLen: 4,
            minLen: 4,
            avgLen: 4,
            maxLen: 4,
            q20Percentage: 100,
            q30Percentage: 100,
            averageQuality: 40,
            gcPercentage: 50
        )
        return PersistedFASTQMetadata(
            computedStatistics: stats,
            ingestion: IngestionMetadata(pairingMode: .singleEnd),
            seqkitStats: seqkitStats
        )
    }

    private func realFASTQImportEnvelope(outputURL: URL) throws -> ProvenanceEnvelope {
        let startedAt = Date(timeIntervalSince1970: 0)
        return try ProvenanceRunBuilder(
            workflowName: "lungfish import fastq",
            workflowVersion: "test",
            toolName: "lungfish import fastq",
            toolVersion: "test"
        )
        .argv(["lungfish", "import", "fastq"])
        .durableReplayArgv(["lungfish", "import", "fastq"])
        .runtime(ProvenanceRuntimeIdentity())
        .output(outputURL, format: .fastq)
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1))
    }

    private func makeURLs(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/fake/path/\($0)") }
    }
}
