// BuildDbTaxTriageODRTests.swift - build-db taxtriage from TaxTriage 3.3.x organism reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

/// `build-db taxtriage` against the trimmed TaxTriage v3.3.8 fixture
/// (`Tests/Fixtures/taxtriage-odr-3.3.8`). The fixture has no BAM, so the samtools
/// read-count pass is skipped and no managed samtools or HOME override is needed.
final class BuildDbTaxTriageODRTests: XCTestCase {

    private func fixtureSampleDir() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Tests/Fixtures/taxtriage-odr-3.3.8/SRR12486983")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("taxtriage-odr-3.3.8 fixture not found")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDbODRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func assertFixtureRows(_ db: TaxTriageDatabase, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try db.fetchSamples().map(\.sample), ["SRR12486983"], file: file, line: line)
        let rows = try db.fetchRows(samples: ["SRR12486983"]).sorted { $0.tassScore > $1.tassScore }
        XCTAssertEqual(rows.count, 5, file: file, line: line)
        XCTAssertEqual(rows.map(\.organism), [
            "Bradyrhizobium sp. WCU1",
            "Human alphaherpesvirus 1",
            "Kocuria sp. BT304",
            "Acinetobacter radioresistens",
            "Chimpanzee herpesvirus strain 105640",
        ], file: file, line: line)
        for (actual, expected) in zip(rows.map(\.tassScore), [1.00, 0.93, 0.92, 0.72, 0.06]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9, file: file, line: line)
        }
        XCTAssertEqual(rows.map(\.confidence), ["High", "High", "High", "Medium", "Low"], file: file, line: line)

        let hsv = rows[1]
        XCTAssertEqual(hsv.taxId, 10298, file: file, line: line)
        XCTAssertEqual(hsv.readsAligned, 1_482_057, file: file, line: line)
        XCTAssertEqual(hsv.k2Reads, 284_492, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(hsv.coverageBreadth), 100.0, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(hsv.meanDepth), 733.8, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(hsv.pctReads), 0.153748, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(hsv.giniCoefficient), 0.92, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(hsv.breadthWeightScore), 0.92, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(hsv.microbialCategory, "Primary", file: file, line: line)
        XCTAssertEqual(hsv.isAnnotated, true, file: file, line: line)
        XCTAssertEqual(hsv.primaryAccession, "NC_001806.2", file: file, line: line)
        XCTAssertNil(hsv.bamPath, "fixture has no minimap2 BAM", file: file, line: line)
        XCTAssertEqual(rows[4].primaryAccession, "NC_023677.1", file: file, line: line)

        let metadata = try db.fetchMetadata()
        XCTAssertEqual(metadata[TaxTriageDatabase.taxonomySourceMetadataKey], "organism_report", file: file, line: line)
        XCTAssertEqual(metadata[TaxTriageDatabase.tassScaleMetadataKey], "0-1", file: file, line: line)
    }

    func testBuildsFromSingleResultODR() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let resultDir = tmp.appendingPathComponent("SRR12486983", isDirectory: true)
        try FileManager.default.copyItem(at: try fixtureSampleDir(), to: resultDir)
        // A Kraken-only top report must not win over the organism report.
        let top = resultDir.appendingPathComponent("top", isDirectory: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        try "abundance\tclade_fragments_covered\tnumber_fragments_assigned\trank\ttaxid\tname\n0.1\t10\t10\tS\t10298\tHuman alphaherpesvirus 1\n"
            .write(to: top.appendingPathComponent("SRR12486983.top_report.tsv"), atomically: true, encoding: .utf8)

        let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "--no-cleanup", "-q"])
        try await cmd.run()

        let db = try TaxTriageDatabase(at: resultDir.appendingPathComponent("taxtriage.sqlite"))
        try assertFixtureRows(db)
    }

    /// The app's serial batch layout: one folder per sample under the batch root,
    /// each with its own `report/all.odr.txt` next to the per-sample ODR.
    func testRebuildsSerialBatchFromPerSampleODRNotCombinedReport() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let batch = tmp.appendingPathComponent("taxtriage-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let sampleDir = batch.appendingPathComponent("SRR12486983", isDirectory: true)
        try FileManager.default.copyItem(at: try fixtureSampleDir(), to: sampleDir)
        // The combined report must be ignored while a per-sample report exists.
        try "Detected Organism\tSpecimen ID\tTASS Score\tTASS Threshold\nDecoy organism\tSRR12486983\t99\t75.0\n"
            .write(to: sampleDir.appendingPathComponent("report/all.odr.txt"), atomically: true, encoding: .utf8)

        // Simulate a database from before this fix: rows present, no taxonomy_source.
        let dbURL = batch.appendingPathComponent("taxtriage.sqlite")
        let staleRow = TaxTriageOrganismReport.parse(
            tsv: try String(contentsOf: sampleDir.appendingPathComponent("report/SRR12486983.odr.txt"), encoding: .utf8)
        )[1]
        let stale = try TaxTriageDatabase.create(at: dbURL, rows: [staleRow], metadata: ["tool": "taxtriage"])
        XCTAssertTrue(stale.isStale(forResultDirectory: batch))

        let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([batch.path, "--force", "--no-cleanup", "-q"])
        try await cmd.run()

        let db = try TaxTriageDatabase(at: dbURL)
        try assertFixtureRows(db)
        XCTAssertFalse(db.isStale(forResultDirectory: batch))
    }
}
