// AnalysesFolderTests.swift - Tests for AnalysesFolder manager
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class AnalysesFolderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-analyses-folder-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testURLCreatesDirectoryIfMissing() throws {
        let url = try AnalysesFolder.url(for: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "Analyses")
    }

    func testURLReturnsExistingDirectory() throws {
        let existing = tempDir.appendingPathComponent("Analyses")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let url = try AnalysesFolder.url(for: tempDir)
        XCTAssertEqual(url.path, existing.path)
    }

    func testCreateAnalysisDirectoryFormatsTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1775398200) // some fixed date
        let url = try AnalysesFolder.createAnalysisDirectory(
            tool: "esviritu", in: tempDir, date: date
        )
        XCTAssertTrue(url.lastPathComponent.hasPrefix("esviritu-"))
        XCTAssertTrue(url.lastPathComponent.contains("2026"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCreateAnalysisDirectoryWritesMetadata() throws {
        let date = Date(timeIntervalSince1970: 1775398200)
        let url = try AnalysesFolder.createAnalysisDirectory(
            tool: "naomgs", in: tempDir, date: date
        )
        let metadata = AnalysesFolder.readAnalysisMetadata(from: url)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.tool, "naomgs")
        XCTAssertEqual(metadata?.isBatch, false)
    }

    func testCreateAnalysisDirectoryIsBatchAware() throws {
        let url = try AnalysesFolder.createAnalysisDirectory(
            tool: "kraken2", in: tempDir, isBatch: true
        )
        XCTAssertTrue(url.lastPathComponent.hasPrefix("kraken2-batch-"))
        let metadata = AnalysesFolder.readAnalysisMetadata(from: url)
        XCTAssertEqual(metadata?.isBatch, true)
    }

    func testListAnalysesFindsAllTypes() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        for name in ["esviritu-2026-01-15T10-00-00", "kraken2-2026-01-15T11-00-00", "spades-2026-01-15T13-00-00"] {
            try FileManager.default.createDirectory(
                at: analysesDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 3)
    }

    func testListAnalysesParseToolAndTimestamp() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00"),
            withIntermediateDirectories: true
        )
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.first?.tool, "esviritu")
        XCTAssertFalse(analyses.first?.isBatch ?? true)
    }

    func testListAnalysesDetectsBatch() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-batch-2026-01-15T15-00-00"),
            withIntermediateDirectories: true
        )
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertTrue(analyses.first?.isBatch ?? false)
    }

    func testListAnalysesIgnoresNonAnalysisDirectories() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("random-folder"),
            withIntermediateDirectories: true
        )
        try "not an analysis".write(
            to: analysesDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 0)
    }

    func testListAnalysesReturnsEmptyForMissingFolder() throws {
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 0)
    }

    func testTimestampFormat() {
        let formatted = AnalysesFolder.formatTimestamp(
            Date(timeIntervalSince1970: 1775398200)
        )
        XCTAssertFalse(formatted.contains(":"))
        XCTAssertTrue(formatted.contains("T"))
    }

    // MARK: - Metadata-Based Detection (Renamed Directories)

    func testListAnalysesDetectsRenamedDirectoryByMetadata() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        // Create a directory with createAnalysisDirectory (writes metadata),
        // then rename it to something unrecognisable by prefix.
        let original = try AnalysesFolder.createAnalysisDirectory(
            tool: "naomgs", in: tempDir
        )
        let renamed = analysesDir.appendingPathComponent("MU-CASPER-2026-03-31")
        try FileManager.default.moveItem(at: original, to: renamed)

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "naomgs")
    }

    func testListAnalysesMetadataTakesPriorityOverContentProbe() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        let dir = analysesDir.appendingPathComponent("Renamed-Analysis")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write metadata saying it's kraken2
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "kraken2", isBatch: false),
            to: dir
        )
        // Also add NAO-MGS content signatures — metadata should win
        try "{\"taxonCount\": 100}".write(
            to: dir.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("hits.sqlite"))

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "kraken2")
    }

    func testReadWriteAnalysisMetadataRoundtrip() throws {
        let dir = tempDir.appendingPathComponent("test-roundtrip")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = AnalysesFolder.AnalysisMetadata(
            tool: "spades", isBatch: true, created: Date(timeIntervalSince1970: 1775398200)
        )
        try AnalysesFolder.writeAnalysisMetadata(original, to: dir)
        let loaded = AnalysesFolder.readAnalysisMetadata(from: dir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.tool, "spades")
        XCTAssertEqual(loaded?.isBatch, true)
        XCTAssertEqual(loaded?.created.timeIntervalSince1970 ?? 0, 1775398200, accuracy: 1)
    }

    func testReadAnalysisMetadataReturnsNilWhenMissing() {
        let result = AnalysesFolder.readAnalysisMetadata(from: tempDir)
        XCTAssertNil(result)
    }

    // MARK: - Content-Based Detection (Renamed Directories, Legacy Fallback)

    func testListAnalysesDetectsRenamedKraken2ByContent() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        let renamed = analysesDir.appendingPathComponent("My-Custom-Name")
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        // Kraken2 signature: classification-result.json
        try "{}".write(to: renamed.appendingPathComponent("classification-result.json"),
                       atomically: true, encoding: .utf8)

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "kraken2")
    }

    func testListAnalysesDetectsRenamedNaoMgsByContent() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        let renamed = analysesDir.appendingPathComponent("MU-CASPER-2026-03-31")
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        // NAO-MGS signature: manifest.json (with taxonCount) + hits.sqlite
        try "{\"taxonCount\": 100}".write(
            to: renamed.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        try Data().write(to: renamed.appendingPathComponent("hits.sqlite"))

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "naomgs")
    }

    func testListAnalysesDetectsRenamedNvdByContent() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        let renamed = analysesDir.appendingPathComponent("Some-NVD-Results")
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        // NVD signature: manifest.json (with experiment) + hits.sqlite
        try "{\"experiment\": \"test\"}".write(
            to: renamed.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        try Data().write(to: renamed.appendingPathComponent("hits.sqlite"))

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "nvd")
    }

    func testListAnalysesDetectsRenamedEsVirituByContent() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        let renamed = analysesDir.appendingPathComponent("Virus-Scan-Results")
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        // EsViritu signature: *.detected_virus.info.tsv
        try "".write(to: renamed.appendingPathComponent("sample.detected_virus.info.tsv"),
                     atomically: true, encoding: .utf8)

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "esviritu")
    }

    func testListAnalysesDetectsRenamedTaxTriageByContent() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        let renamed = analysesDir.appendingPathComponent("Triage-Output")
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        // TaxTriage signature: hits.sqlite alone (no manifest.json)
        try Data().write(to: renamed.appendingPathComponent("hits.sqlite"))

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "taxtriage")
    }

    func testListAnalysesDetectsRenamedAssemblyByResultSidecar() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        let renamed = analysesDir.appendingPathComponent("LongReadAssembly")
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        try """
        {
          "schemaVersion": 2,
          "tool": "flye",
          "readType": "ontReads",
          "contigsPath": "assembly.fasta",
          "commandLine": "flye --nano-hq reads.fastq.gz",
          "outputDirectory": "\(renamed.path)",
          "statistics": {
            "contigCount": 1,
            "scaffoldCount": 0,
            "totalLengthBP": 12000,
            "n50": 12000,
            "n90": 12000,
            "l50": 1,
            "l90": 1,
            "largestContigBP": 12000,
            "smallestContigBP": 12000,
            "meanContigBP": 12000.0,
            "medianContigBP": 12000.0,
            "gcPercent": 50.0
          },
          "wallTimeSeconds": 15.0
        }
        """.write(
            to: renamed.appendingPathComponent("assembly-result.json"),
            atomically: true,
            encoding: .utf8
        )

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "flye")
    }

    func testListAnalysesStillIgnoresEmptyRenamedDirectories() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        // Empty directory with no tool-prefix and no signature files
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("random-renamed-thing"),
            withIntermediateDirectories: true
        )
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 0)
    }

    func testListAnalysesPrefersToolPrefixOverContentProbe() throws {
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        // Directory has a valid kraken2 prefix AND naomgs content — prefix should win
        let dir = analysesDir.appendingPathComponent("kraken2-2026-01-15T10-00-00")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"taxonCount\": 100}".write(
            to: dir.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("hits.sqlite"))

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "kraken2")
    }
}
