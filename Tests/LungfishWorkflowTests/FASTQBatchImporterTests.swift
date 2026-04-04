// FASTQBatchImporterTests.swift - Unit tests for FASTQBatchImporter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO

final class FASTQBatchImporterTests: XCTestCase {

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

    func testRecipeResolutionAmplicon() throws {
        let recipe = try FASTQBatchImporter.resolveRecipe(named: "amplicon")
        XCTAssertEqual(recipe.name, ProcessingRecipe.targetedAmplicon.name)
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
        let importsDir = tmpDir.appendingPathComponent("Imports")
        let bundleURL = importsDir.appendingPathComponent("SampleX.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pair = SamplePair(sampleName: "SampleX", r1: URL(fileURLWithPath: "/tmp/x_R1.fastq.gz"), r2: nil)
        XCTAssertTrue(FASTQBatchImporter.bundleExists(for: pair, in: tmpDir), "Should detect existing bundle")
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
        let importsDir = tmpDir.appendingPathComponent("Imports")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pre-create bundles for all samples so they should all be skipped
        let sampleNames = ["Alpha", "Beta", "Gamma"]
        for name in sampleNames {
            let bundleURL = importsDir.appendingPathComponent("\(name).lungfishfastq")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
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

    // MARK: - Helpers

    private func makeURLs(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/fake/path/\($0)") }
    }
}
