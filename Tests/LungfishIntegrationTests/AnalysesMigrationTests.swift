// AnalysesMigrationTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class AnalysesMigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-migration-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testMigrateEsVirituFromDerivatives() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let derivDir = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("esviritu-abc123")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)
        // Copy esviritu-result.json from fixture
        try FileManager.default.copyItem(
            at: TestAnalysisFixtures.esvirituResult.appendingPathComponent("esviritu-result.json"),
            to: derivDir.appendingPathComponent("esviritu-result.json")
        )

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 1)

        // Verify moved to Analyses/
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.tool, "esviritu")

        // Verify removed from derivatives
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivDir.path))

        // Verify manifest created
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: tempDir)
        XCTAssertEqual(manifest.analyses.count, 1)
    }

    func testMigrateClassificationFromDerivatives() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let derivDir = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("classification-xyz789")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestAnalysisFixtures.kraken2Result.appendingPathComponent("classification-result.json"),
            to: derivDir.appendingPathComponent("classification-result.json")
        )

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 1)
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.first?.tool, "kraken2")
    }

    func testMigrateFindsFASTQBundlesInsideProjectFolders() throws {
        let bundleDir = tempDir
            .appendingPathComponent("Samples", isDirectory: true)
            .appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let derivDir = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("classification-nested")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestAnalysisFixtures.kraken2Result.appendingPathComponent("classification-result.json"),
            to: derivDir.appendingPathComponent("classification-result.json")
        )

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)

        XCTAssertEqual(migrated, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivDir.path))
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.first?.tool, "kraken2")
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: tempDir)
        XCTAssertEqual(manifest.analyses.count, 1)
    }

    func testMigrateDoesNotMoveFASTQDerivatives() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let fastqDeriv = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("trimmed.lungfishfastq")
        try FileManager.default.createDirectory(at: fastqDeriv, withIntermediateDirectories: true)

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastqDeriv.path))
    }

    func testMigrateIsIdempotent() throws {
        // Pre-populate Analyses/ — should not try to re-migrate
        let analysesDir = try AnalysesFolder.url(for: tempDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00"),
            withIntermediateDirectories: true
        )
        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 0)
    }

    func testMigrateMultipleResults() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        // Create esviritu result
        let esDir = bundleDir.appendingPathComponent("derivatives/esviritu-aaa")
        try FileManager.default.createDirectory(at: esDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestAnalysisFixtures.esvirituResult.appendingPathComponent("esviritu-result.json"),
            to: esDir.appendingPathComponent("esviritu-result.json")
        )
        // Create classification result
        let clDir = bundleDir.appendingPathComponent("derivatives/classification-bbb")
        try FileManager.default.createDirectory(at: clDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestAnalysisFixtures.kraken2Result.appendingPathComponent("classification-result.json"),
            to: clDir.appendingPathComponent("classification-result.json")
        )

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 2)
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 2)
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: tempDir)
        XCTAssertEqual(manifest.analyses.count, 2)
    }

    func testMigrateResultsWithSameToolAndTimestampUsesUniqueDestinations() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let firstDir = bundleDir.appendingPathComponent("derivatives/esviritu-aaa")
        let secondDir = bundleDir.appendingPathComponent("derivatives/esviritu-bbb")
        for dir in [firstDir, secondDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: TestAnalysisFixtures.esvirituResult.appendingPathComponent("esviritu-result.json"),
                to: dir.appendingPathComponent("esviritu-result.json")
            )
        }

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)

        XCTAssertEqual(migrated, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDir.path))

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        let analysisNames = Set(analyses.map { $0.url.lastPathComponent })
        XCTAssertEqual(analysisNames.count, 2)
        let savedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-15T10:00:00Z"))
        let expectedBaseName = "esviritu-\(AnalysesFolder.formatTimestamp(savedAt))"
        XCTAssertTrue(analysisNames.contains(expectedBaseName))
        XCTAssertTrue(analysisNames.contains("\(expectedBaseName)-2"))

        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: tempDir)
        XCTAssertEqual(Set(manifest.analyses.map(\.analysisDirectoryName)), analysisNames)
    }

    func testMigrateRollsBackWhenManifestRecordFails() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let corruptManifestURL = bundleDir.appendingPathComponent(AnalysisManifest.filename)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let corruptData = Data("{ broken json".utf8)
        try corruptData.write(to: corruptManifestURL, options: .atomic)

        let derivDir = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("esviritu-abc123")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestAnalysisFixtures.esvirituResult.appendingPathComponent("esviritu-result.json"),
            to: derivDir.appendingPathComponent("esviritu-result.json")
        )

        XCTAssertThrowsError(try AnalysesMigration.migrateProject(at: tempDir))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: derivDir.path),
            "Analysis directory should remain in derivatives when manifest recording fails."
        )
        XCTAssertTrue(try AnalysesFolder.listAnalyses(in: tempDir).isEmpty)
        XCTAssertEqual(try Data(contentsOf: corruptManifestURL), corruptData)
    }

    func testMigrateTimestampExtractedFromSidecar() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let derivDir = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("esviritu-abc123")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestAnalysisFixtures.esvirituResult.appendingPathComponent("esviritu-result.json"),
            to: derivDir.appendingPathComponent("esviritu-result.json")
        )

        try AnalysesMigration.migrateProject(at: tempDir)

        // The fixture savedAt is "2026-01-15T10:00:00Z" — verify the directory name reflects it
        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        XCTAssertEqual(analyses.count, 1)
        // The timestamp embedded in the directory name should come from the sidecar
        let dirName = analyses.first?.url.lastPathComponent ?? ""
        XCTAssertTrue(dirName.hasPrefix("esviritu-2026-01-15T"), "Expected timestamp from sidecar, got \(dirName)")
    }

    func testMigrateTimestampExtractedFromNaoMgsManifest() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let derivDir = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("naomgs-legacy")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)
        try """
        {
          "formatVersion": "1.0",
          "sampleName": "sample",
          "importDate": "2026-02-16T11:12:13Z",
          "sourceFilePath": "/tmp/virus_hits_final.tsv.gz",
          "hitCount": 2,
          "taxonCount": 1,
          "fetchedAccessions": []
        }
        """.write(to: derivDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try AnalysesMigration.migrateProject(at: tempDir)

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        let dirName = try XCTUnwrap(analyses.first?.url.lastPathComponent)
        let importDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-02-16T11:12:13Z"))
        let expectedName = "naomgs-\(AnalysesFolder.formatTimestamp(importDate))"
        XCTAssertTrue(dirName.hasPrefix(expectedName), "Expected importDate from manifest, got \(dirName)")
    }

    func testMigrateTimestampExtractedFromNvdManifest() throws {
        let bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        let derivDir = bundleDir.appendingPathComponent("derivatives")
            .appendingPathComponent("nvd-legacy")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)
        try """
        {
          "formatVersion": "1.0",
          "experiment": "100",
          "importDate": "2026-03-17T12:13:14Z",
          "sampleCount": 1,
          "contigCount": 2,
          "hitCount": 3,
          "sourceDirectoryPath": "/tmp/nvd",
          "samples": [],
          "cachedTopContigs": []
        }
        """.write(to: derivDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try AnalysesMigration.migrateProject(at: tempDir)

        let analyses = try AnalysesFolder.listAnalyses(in: tempDir)
        let dirName = try XCTUnwrap(analyses.first?.url.lastPathComponent)
        let importDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-17T12:13:14Z"))
        let expectedName = "nvd-\(AnalysesFolder.formatTimestamp(importDate))"
        XCTAssertTrue(dirName.hasPrefix(expectedName), "Expected importDate from manifest, got \(dirName)")
    }

    func testMigrateIgnoresNonBundles() throws {
        // A plain directory (not .lungfishfastq) with analysis derivatives should be ignored
        let plainDir = tempDir.appendingPathComponent("notabundle")
        let derivDir = plainDir.appendingPathComponent("derivatives/esviritu-abc123")
        try FileManager.default.createDirectory(at: derivDir, withIntermediateDirectories: true)

        let migrated = try AnalysesMigration.migrateProject(at: tempDir)
        XCTAssertEqual(migrated, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: derivDir.path))
    }
}
