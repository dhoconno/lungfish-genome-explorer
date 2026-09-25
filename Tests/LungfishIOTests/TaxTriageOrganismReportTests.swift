// TaxTriageOrganismReportTests.swift - TaxTriage 3.3.x organism discovery report parsing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class TaxTriageOrganismReportTests: XCTestCase {

    // MARK: - Fixture

    /// `Tests/Fixtures/taxtriage-odr-3.3.8/SRR12486983`, trimmed from a real TaxTriage
    /// v3.3.8 run on public SRA data (see the fixture README).
    private func fixtureSampleDir() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Tests/Fixtures/taxtriage-odr-3.3.8/SRR12486983")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("taxtriage-odr-3.3.8 fixture not found")
    }

    private func fixtureODR() throws -> URL {
        try fixtureSampleDir().appendingPathComponent("report/SRR12486983.odr.txt")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageODRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - File classification

    func testPerSampleReportFileNames() {
        func url(_ path: String) -> URL { URL(fileURLWithPath: "/r/\(path)") }

        XCTAssertTrue(TaxTriageOrganismReport.isPerSampleReportFile(url("report/SRR12486983.odr.txt")))
        XCTAssertEqual(TaxTriageOrganismReport.sampleID(fromReportFile: url("report/SRR12486983.odr.txt")), "SRR12486983")
        XCTAssertTrue(TaxTriageOrganismReport.isPerSampleReportFile(url("report/S1.organisms.report.txt")))
        XCTAssertEqual(TaxTriageOrganismReport.sampleID(fromReportFile: url("S1.organisms.report.txt")), "S1")

        // The combined report is an organism report but never a per-sample one.
        XCTAssertFalse(TaxTriageOrganismReport.isPerSampleReportFile(url("report/all.odr.txt")))
        XCTAssertTrue(TaxTriageOrganismReport.isCombinedReportFile(url("report/all.odr.txt")))

        // Files the old `name.contains("report")` rule mistook for organism reports.
        for name in [
            "kraken2/SRR12486983.kraken2.report.txt",
            "top/SRR12486983.top_report.tsv",
            "kreport/SRR12486983.krakenreport.krona.txt",
            "report/SRR12486983.odr.xlsx",
            "report/SRR12486983.odr.pdf",
            "report/all.odr.json",
        ] {
            XCTAssertFalse(TaxTriageOrganismReport.isPerSampleReportFile(url(name)), name)
        }
    }

    func testReportFilesPreferPerSampleOverCombined() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("report", isDirectory: true)
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        try "x".write(to: report.appendingPathComponent("all.odr.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            TaxTriageOrganismReport.reportFiles(inResultDirectory: dir).map(\.lastPathComponent),
            ["all.odr.txt"],
            "the combined report is the fallback when no per-sample report exists"
        )

        try "x".write(to: report.appendingPathComponent("S1.odr.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: report.appendingPathComponent("S1.organisms.report.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: report.appendingPathComponent("S2.odr.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            TaxTriageOrganismReport.reportFiles(inResultDirectory: dir).map(\.lastPathComponent),
            ["S1.odr.txt", "S2.odr.txt"]
        )

        let batch = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: batch) }
        XCTAssertFalse(TaxTriageOrganismReport.containsReportFiles(inResultOrBatchDirectory: batch))
        try FileManager.default.copyItem(at: dir, to: batch.appendingPathComponent("S1"))
        XCTAssertTrue(TaxTriageOrganismReport.containsReportFiles(inResultOrBatchDirectory: batch))
    }

    // MARK: - ODR parsing

    func testParsesODRFixtureWithExactValues() throws {
        let url = try fixtureODR()
        let header = try XCTUnwrap(
            try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").first
        ).components(separatedBy: "\t")
        XCTAssertEqual(TaxTriageOrganismReport.format(ofHeader: header), .organismDiscoveryReport)

        let rows = try TaxTriageOrganismReport.parse(url: url)
        XCTAssertEqual(rows.map(\.organism), [
            "Bradyrhizobium sp. WCU1",
            "Human alphaherpesvirus 1",
            "Kocuria sp. BT304",
            "Acinetobacter radioresistens",
            "Chimpanzee herpesvirus strain 105640",
        ])
        XCTAssertEqual(Set(rows.map(\.sample)), ["SRR12486983"])

        // TASS Score column values 100, 93, 92, 72, 6 on TaxTriage's 0-100 scale.
        let tass = rows.map(\.tassScore)
        for (actual, expected) in zip(tass, [1.00, 0.93, 0.92, 0.72, 0.06]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
        // Passes Threshold TRUE/TRUE/TRUE/FALSE/FALSE against TASS Threshold 75.0.
        XCTAssertEqual(rows.map(\.confidence), ["High", "High", "High", "Medium", "Low"])

        let hsv = rows[1]
        XCTAssertEqual(hsv.taxId, 10298)
        XCTAssertEqual(hsv.status, "established")
        XCTAssertEqual(hsv.readsAligned, 1_482_057)
        XCTAssertEqual(try XCTUnwrap(hsv.pctReads), 0.153748, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.pctAlignedReads), 15.3748, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.coverageBreadth), 100.0, accuracy: 1e-9)
        XCTAssertNil(hsv.meanCoverage)
        XCTAssertEqual(try XCTUnwrap(hsv.meanDepth), 733.8, accuracy: 1e-9)
        XCTAssertEqual(hsv.k2Reads, 284_492)
        XCTAssertEqual(hsv.parentK2Reads, 0)
        XCTAssertEqual(try XCTUnwrap(hsv.giniCoefficient), 0.92, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.meanBaseQ), 30.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.meanMapQ), 57.74, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.mapqScore), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.disparityScore), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.minhashScore), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.diamondIdentity), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.k2DisparityScore), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.siblingsScore), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.breadthWeightScore), 0.92, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsv.hhsPercentile), 100.0, accuracy: 1e-9)
        XCTAssertEqual(hsv.isAnnotated, true)
        XCTAssertEqual(hsv.annClass, "Derived")
        XCTAssertEqual(hsv.microbialCategory, "Primary")
        XCTAssertEqual(hsv.highConsequence, false)
        XCTAssertEqual(hsv.isSpecies, false)
        XCTAssertNil(hsv.pathogenicSubstrains)
        XCTAssertEqual(hsv.sampleType, "unknown")
        XCTAssertNil(hsv.bamPath)
        XCTAssertNil(hsv.primaryAccession)

        // Breadth % wins over the rounded "32%" Coverage string.
        let brady = rows[0]
        XCTAssertEqual(try XCTUnwrap(brady.coverageBreadth), 31.78, accuracy: 1e-9)
        XCTAssertNil(brady.status, "blank Status stays empty")
        XCTAssertEqual(brady.readsAligned, 48_380)

        let chimp = rows[4]
        XCTAssertEqual(chimp.taxId, 332_937)
        XCTAssertEqual(chimp.readsAligned, 24)
        XCTAssertEqual(try XCTUnwrap(chimp.coverageBreadth), 0.48, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(chimp.mapqScore), 0.84, accuracy: 1e-9)
        XCTAssertEqual(chimp.annClass, "Direct")
    }

    func testCombinedReportRowsKeepTheirSpecimenID() throws {
        let odr = try String(contentsOf: try fixtureODR(), encoding: .utf8)
        var lines = odr.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Re-label the last row as a second specimen, as all.odr.txt would in a multi-sample run.
        lines[lines.count - 1] = lines[lines.count - 1]
            .replacingOccurrences(of: "\tSRR12486983\t", with: "\tSRR12486989\t")
        let rows = TaxTriageOrganismReport.parse(
            tsv: lines.joined(separator: "\n"),
            fallbackSample: nil
        )
        XCTAssertEqual(rows.filter { $0.sample == "SRR12486983" }.count, 4)
        XCTAssertEqual(rows.filter { $0.sample == "SRR12486989" }.map(\.organism),
                       ["Chimpanzee herpesvirus strain 105640"])
    }

    func testLegacyConfidenceTableKeepsItsScaleAndGroupLabel() {
        let tsv = """
        Sample\tindex\tDetected Organism\tSpecimen ID\t% Reads\t# Reads Aligned\tCoverage\tTaxonomic ID #\tStatus\tTASS Score\tGroup
        1227\t0\tBovine coronavirus°\tSRR35517703\t8.5e-05\t3\t0.01\t11128\testablished\t0.25\tUnknown
        """
        let rows = TaxTriageOrganismReport.parse(tsv: tsv)
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.organism, "Bovine coronavirus")
        XCTAssertEqual(row.sample, "SRR35517703")
        XCTAssertEqual(row.tassScore, 0.25, accuracy: 1e-9)
        XCTAssertEqual(row.confidence, "Unknown")
        XCTAssertEqual(try XCTUnwrap(row.pctReads), 8.5e-05, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(row.coverageBreadth), 0.01, accuracy: 1e-9)
        XCTAssertEqual(row.readsAligned, 3)
    }

    func testConfidenceLabelUsesTaxTriageThresholdCall() {
        XCTAssertEqual(TaxTriageOrganismReport.odrConfidenceLabel(tassScore: 0.76, passesThreshold: true, threshold: 0.75), "High")
        XCTAssertEqual(TaxTriageOrganismReport.odrConfidenceLabel(tassScore: 0.74, passesThreshold: nil, threshold: 0.75), "Medium")
        XCTAssertEqual(TaxTriageOrganismReport.odrConfidenceLabel(tassScore: 0.1, passesThreshold: false, threshold: 0.75), "Low")
        XCTAssertEqual(TaxTriageOrganismReport.odrConfidenceLabel(tassScore: 0.85, passesThreshold: nil, threshold: nil), "High")
        XCTAssertNil(TaxTriageOrganismReport.odrConfidenceLabel(tassScore: nil, passesThreshold: true, threshold: 0.75))
    }

    // MARK: - Stale database detection

    func testDatabaseWithoutTaxonomySourceIsStaleWhenODRExists() throws {
        let batch = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: batch) }
        try FileManager.default.copyItem(at: try fixtureSampleDir(), to: batch.appendingPathComponent("SRR12486983"))

        let row = TaxTriageOrganismReport.parse(tsv: try String(contentsOf: try fixtureODR(), encoding: .utf8))[0]

        let legacyURL = batch.appendingPathComponent("legacy.sqlite")
        let legacy = try TaxTriageDatabase.create(at: legacyURL, rows: [row], metadata: ["tool": "taxtriage"])
        XCTAssertTrue(legacy.isStale(forResultDirectory: batch))

        let currentURL = batch.appendingPathComponent("current.sqlite")
        let current = try TaxTriageDatabase.create(
            at: currentURL,
            rows: [row],
            metadata: ["tool": "taxtriage", TaxTriageDatabase.taxonomySourceMetadataKey: "organism_report"]
        )
        XCTAssertFalse(current.isStale(forResultDirectory: batch))

        let emptyDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        XCTAssertFalse(legacy.isStale(forResultDirectory: emptyDir),
                       "a legacy database without any organism report stays as it is")
    }
}
