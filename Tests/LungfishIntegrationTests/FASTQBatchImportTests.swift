// FASTQBatchImportTests.swift
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

/// Thread-safe accumulator for log event JSON strings, used to satisfy Swift 6
/// `@Sendable` closure capture rules in async batch-import tests.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    var events: [String] {
        lock.withLock { _events }
    }
}

final class FASTQBatchImportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: - Pair Detection

    func testPairDetectionFromFixtures() throws {
        let r1 = TestFixtures.sarscov2.fastqR1
        let r2 = TestFixtures.sarscov2.fastqR2
        let pairs = FASTQBatchImporter.detectPairs(from: [r1, r2])
        XCTAssertEqual(pairs.count, 1, "Should detect one paired sample")
        XCTAssertNotNil(pairs.first?.r2, "Should detect R2")
        XCTAssertEqual(pairs.first?.sampleName, "test")
    }

    func testPairDetectionSingleEnd() throws {
        let r1 = TestFixtures.sarscov2.fastqR1
        let pairs = FASTQBatchImporter.detectPairs(from: [r1])
        XCTAssertEqual(pairs.count, 1, "Should detect one single-end sample")
        XCTAssertNil(pairs.first?.r2, "Single-end sample should have no R2")
    }

    func testPairDetectionEmptyList() throws {
        let pairs = FASTQBatchImporter.detectPairs(from: [])
        XCTAssertTrue(pairs.isEmpty, "Empty input should yield empty pairs")
    }

    // MARK: - Bundle Existence / Skip Logic

    func testBundleDoesNotExistInitially() throws {
        let pair = SamplePair(
            sampleName: "test",
            r1: TestFixtures.sarscov2.fastqR1,
            r2: TestFixtures.sarscov2.fastqR2
        )
        XCTAssertFalse(FASTQBatchImporter.bundleExists(for: pair, in: tempDir))
    }

    func testBundleExistsAfterCreatingDirectory() throws {
        let pair = SamplePair(
            sampleName: "test",
            r1: TestFixtures.sarscov2.fastqR1,
            r2: TestFixtures.sarscov2.fastqR2
        )

        // Create the expected bundle directory at Imports/<sampleName>.lungfishfastq
        let bundleDir = tempDir
            .appendingPathComponent("Imports")
            .appendingPathComponent("test.\(FASTQBundle.directoryExtension)")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        XCTAssertTrue(FASTQBatchImporter.bundleExists(for: pair, in: tempDir))
    }

    func testBundleExistsWrongNameReturnsFalse() throws {
        let pair = SamplePair(
            sampleName: "test",
            r1: TestFixtures.sarscov2.fastqR1,
            r2: TestFixtures.sarscov2.fastqR2
        )

        // Create a bundle for a DIFFERENT sample name
        let bundleDir = tempDir
            .appendingPathComponent("Imports")
            .appendingPathComponent("other.\(FASTQBundle.directoryExtension)")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        XCTAssertFalse(FASTQBatchImporter.bundleExists(for: pair, in: tempDir))
    }

    // MARK: - Structured Log Events

    func testLogEventImportStart() throws {
        let event = ImportLogEvent.importStart(sampleCount: 5, recipeName: "wgs")
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("\"event\""), "JSON must contain event key")
        XCTAssertTrue(json.contains("importStart"), "importStart event name")
        XCTAssertTrue(json.contains("5"), "sample count present")
        XCTAssertTrue(json.contains("wgs"), "recipe name present")
    }

    func testLogEventSampleStart() throws {
        let event = ImportLogEvent.sampleStart(
            sample: "test", index: 1, total: 1,
            r1: "test_1.fastq.gz", r2: "test_2.fastq.gz"
        )
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("sampleStart"), "sampleStart event name")
        XCTAssertTrue(json.contains("\"sample\""), "sample key present")
        XCTAssertTrue(json.contains("\"test\""), "sample value present")
        XCTAssertTrue(json.contains("test_1.fastq.gz"), "r1 filename present")
        XCTAssertTrue(json.contains("test_2.fastq.gz"), "r2 filename present")
    }

    func testLogEventSampleStartNoR2() throws {
        let event = ImportLogEvent.sampleStart(
            sample: "solo", index: 0, total: 1,
            r1: "solo.fastq.gz", r2: nil
        )
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("sampleStart"), "sampleStart event name")
        XCTAssertFalse(json.contains("\"r2\""), "r2 key should be absent when nil")
    }

    func testLogEventImportComplete() throws {
        let event = ImportLogEvent.importComplete(
            completed: 10, skipped: 2, failed: 1, totalDurationSeconds: 500.0
        )
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("importComplete"), "importComplete event name")
        XCTAssertTrue(json.contains("10"), "completed count present")
        XCTAssertTrue(json.contains("500"), "duration present")
    }

    func testLogEventSampleSkip() throws {
        let event = ImportLogEvent.sampleSkip(sample: "test", reason: "Bundle already exists")
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("sampleSkip"), "sampleSkip event name")
        XCTAssertTrue(json.contains("Bundle already exists"), "reason present")
    }

    func testLogEventSampleFailed() throws {
        let event = ImportLogEvent.sampleFailed(sample: "bad", error: "File not found")
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("sampleFailed"), "sampleFailed event name")
        XCTAssertTrue(json.contains("File not found"), "error message present")
    }

    func testLogEventAlwaysContainsTimestamp() throws {
        let event = ImportLogEvent.importStart(sampleCount: 1, recipeName: nil)
        let json = FASTQBatchImporter.encodeLogEvent(event)
        XCTAssertTrue(json.contains("\"timestamp\""), "timestamp key always present")
    }

    // MARK: - Batch Import: Skip Existing Bundles

    func testBatchImportSkipsAllExisting() async throws {
        let projectDir = tempDir!

        // Create the expected bundle directory so the importer will skip this sample
        let bundleDir = projectDir
            .appendingPathComponent("Imports")
            .appendingPathComponent("test.\(FASTQBundle.directoryExtension)")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let pairs = [SamplePair(
            sampleName: "test",
            r1: TestFixtures.sarscov2.fastqR1,
            r2: TestFixtures.sarscov2.fastqR2
        )]

        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectDir,
            recipe: nil,
            qualityBinning: .illumina4,
            threads: 4,
            logDirectory: nil
        )

        let collector = EventCollector()
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: pairs,
            config: config,
            log: { event in
                let json = FASTQBatchImporter.encodeLogEvent(event)
                collector.append(json)
            }
        )
        let events = collector.events

        XCTAssertEqual(result.completed, 0, "No samples should complete (all skipped)")
        XCTAssertEqual(result.skipped, 1, "The pre-existing bundle should be skipped")
        XCTAssertEqual(result.failed, 0, "No samples should fail")
        XCTAssertTrue(
            events.contains(where: { $0.contains("importStart") }),
            "Should emit importStart event"
        )
        XCTAssertTrue(
            events.contains(where: { $0.contains("sampleSkip") }),
            "Should emit sampleSkip event for existing bundle"
        )
        XCTAssertTrue(
            events.contains(where: { $0.contains("importComplete") }),
            "Should emit importComplete event"
        )
    }

    func testBatchImportEmitsImportStartAndComplete() async throws {
        let projectDir = tempDir!

        // Provide empty pairs list so no real I/O happens
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectDir,
            recipe: nil,
            qualityBinning: .illumina4,
            threads: 4,
            logDirectory: nil
        )

        let collector = EventCollector()
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [],
            config: config,
            log: { event in
                let json = FASTQBatchImporter.encodeLogEvent(event)
                collector.append(json)
            }
        )
        let events = collector.events

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(
            events.contains(where: { $0.contains("importStart") }),
            "Should always emit importStart"
        )
        XCTAssertTrue(
            events.contains(where: { $0.contains("importComplete") }),
            "Should always emit importComplete"
        )
    }

    // MARK: - Recipe Resolution

    func testResolveKnownRecipes() throws {
        let recipes = ["vsp2", "wgs", "amplicon", "hifi"]
        for name in recipes {
            XCTAssertNoThrow(
                try FASTQBatchImporter.resolveRecipe(named: name),
                "Recipe '\(name)' should resolve without error"
            )
        }
    }

    func testResolveRecipeCaseInsensitive() throws {
        XCTAssertNoThrow(try FASTQBatchImporter.resolveRecipe(named: "WGS"))
        XCTAssertNoThrow(try FASTQBatchImporter.resolveRecipe(named: "Amplicon"))
    }

    func testResolveUnknownRecipeThrows() throws {
        XCTAssertThrowsError(try FASTQBatchImporter.resolveRecipe(named: "unknown")) { error in
            guard case BatchImportError.unknownRecipe(let name) = error else {
                return XCTFail("Expected BatchImportError.unknownRecipe, got \(error)")
            }
            XCTAssertEqual(name, "unknown")
        }
    }
}
