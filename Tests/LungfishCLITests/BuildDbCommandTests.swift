// BuildDbCommandTests.swift - Tests for the build-db CLI command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDbTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Locates the taxtriage-mini fixture directory by walking up from the source file.
    private func findFixtureDir(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Tests/Fixtures/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        fatalError("Could not find fixture directory: \(name)")
    }

    // MARK: - Tests

    /// Verifies that the command parses confidence TSV, resolves BAM paths and
    /// accessions, and produces a valid SQLite database.
    func testBuildDbTaxTriage() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Run command with --quiet to suppress output
        var cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // Verify database was created
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path),
                       "Database file should exist after build")

        // Open and verify contents
        let db = try TaxTriageDatabase(at: dbURL)
        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 3, "Should have 3 samples (SRR35517702, SRR35517703, SRR35517705)")

        let allSampleIds = samples.map(\.sample).sorted()
        XCTAssertEqual(allSampleIds, ["SRR35517702", "SRR35517703", "SRR35517705"])

        let allRows = try db.fetchRows(samples: allSampleIds)
        XCTAssertEqual(allRows.count, 15, "Fixture has 15 data rows")

        // Verify a specific row has expected fields
        let sarscov2Rows = allRows.filter { $0.organism.contains("Severe acute respiratory syndrome") }
        XCTAssertEqual(sarscov2Rows.count, 3, "SARS-CoV-2 appears in all 3 samples")

        // Check one specific row in detail
        let srr702Sars = sarscov2Rows.first { $0.sample == "SRR35517702" }
        XCTAssertNotNil(srr702Sars)
        if let row = srr702Sars {
            XCTAssertEqual(row.taxId, 2697049)
            XCTAssertEqual(row.status, "established")
            XCTAssertEqual(row.tassScore, 0.66, accuracy: 0.01)
            XCTAssertEqual(row.readsAligned, 31)
            XCTAssertNil(row.uniqueReads, "Unique reads should be nil (not computed)")
            XCTAssertEqual(row.highConsequence, true)
            XCTAssertEqual(row.isAnnotated, true)
            XCTAssertEqual(row.confidence, "Unknown")
            XCTAssertNotNil(row.primaryAccession, "Should have accession from gcfmap")
            XCTAssertEqual(row.primaryAccession, "NC_045512.2")
        }

        // Verify BAM path resolution
        let withBam = allRows.filter { $0.bamPath != nil }
        XCTAssertEqual(withBam.count, allRows.count, "All rows should have BAM paths (fixtures include BAM files)")

        // Verify metadata
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool"], "taxtriage")
        XCTAssertNotNil(meta["created_at"])
    }

    /// Verifies that the command skips building when a database already exists
    /// and --force is not specified.
    func testBuildDbSkipsExisting() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Create empty DB file as a sentinel
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())

        // Run without --force — should skip
        var cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // DB should still be empty (0 bytes) — not rebuilt
        let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        XCTAssertEqual(attrs[.size] as? Int, 0,
                       "Database should remain empty when --force is not specified")
    }

    /// Verifies that --force causes an existing database to be rebuilt.
    func testBuildDbForceRebuild() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Create empty DB file
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())

        // Run WITH --force — should rebuild
        var cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "--force", "-q"])
        try await cmd.run()

        // DB should now have content
        let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        XCTAssertGreaterThan(attrs[.size] as? Int ?? 0, 0,
                             "Database should be rebuilt with --force")
    }

    /// Verifies that post-build cleanup removes intermediate directories and fastp
    /// FASTQ files while preserving QC reports and essential result directories.
    func testTaxTriageCleanupRemovesIntermediateFiles() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Create fake intermediate directories that cleanup should remove
        let fm = FileManager.default
        for dirname in ["count", "filterkraken", "get", "map", "samtools", "bedtools"] {
            let dir = resultDir.appendingPathComponent(dirname)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Add a dummy file so directory isn't empty
            fm.createFile(atPath: dir.appendingPathComponent("dummy.txt").path, contents: Data("test".utf8))
        }

        // Create fastp/ with both FASTQ (should be removed) and HTML/JSON (should be kept)
        let fastpDir = resultDir.appendingPathComponent("fastp")
        try fm.createDirectory(at: fastpDir, withIntermediateDirectories: true)
        fm.createFile(atPath: fastpDir.appendingPathComponent("sample.fastp.fastq.gz").path, contents: Data("fastq".utf8))
        fm.createFile(atPath: fastpDir.appendingPathComponent("sample.fastp.html").path, contents: Data("report".utf8))
        fm.createFile(atPath: fastpDir.appendingPathComponent("sample.fastp.json").path, contents: Data("report".utf8))

        // Run build-db (cleanup enabled by default)
        var cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // Verify intermediate dirs are gone
        XCTAssertFalse(fm.fileExists(atPath: resultDir.appendingPathComponent("count").path),
                       "count/ should be removed by cleanup")
        XCTAssertFalse(fm.fileExists(atPath: resultDir.appendingPathComponent("filterkraken").path),
                       "filterkraken/ should be removed by cleanup")
        XCTAssertFalse(fm.fileExists(atPath: resultDir.appendingPathComponent("get").path),
                       "get/ should be removed by cleanup")

        // Verify essential dirs are kept
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("report").path),
                      "report/ should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("minimap2").path),
                      "minimap2/ should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("combine").path),
                      "combine/ should be preserved")

        // Verify fastp/ HTML and JSON reports are kept, FASTQ removed
        XCTAssertTrue(fm.fileExists(atPath: fastpDir.appendingPathComponent("sample.fastp.html").path),
                      "fastp HTML report should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: fastpDir.appendingPathComponent("sample.fastp.json").path),
                      "fastp JSON report should be preserved")
        XCTAssertFalse(fm.fileExists(atPath: fastpDir.appendingPathComponent("sample.fastp.fastq.gz").path),
                       "fastp FASTQ file should be removed by cleanup")
    }

    /// Verifies that --no-cleanup preserves all intermediate directories.
    func testTaxTriageNoCleanupPreservesAll() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Create fake intermediate directories
        let fm = FileManager.default
        for dirname in ["count", "filterkraken"] {
            let dir = resultDir.appendingPathComponent(dirname)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent("dummy.txt").path, contents: Data("test".utf8))
        }

        // Run with --no-cleanup
        var cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "--no-cleanup", "-q"])
        try await cmd.run()

        // All directories should still exist
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("count").path),
                      "count/ should be preserved with --no-cleanup")
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("filterkraken").path),
                      "filterkraken/ should be preserved with --no-cleanup")
    }
}
