// CzIdDataConverterTests.swift - Tests for CZ-ID classification import conversion
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class CzIdDataConverterTests: XCTestCase {
    func testParsesMinimalTaxonReportAndMetadata() throws {
        let fixture = fixtureURL("minimal_taxon_report.tsv")

        let parsed = try CzIdDataConverter.parseTaxonReport(at: fixture)

        XCTAssertEqual(parsed.metadata.sampleName, "Sample-CZ-001")
        XCTAssertEqual(parsed.metadata.projectId, "Project-42")
        XCTAssertEqual(parsed.metadata.pipelineVersion, "8.4")
        XCTAssertEqual(parsed.metadata.ntDatabaseVersion, "nt_2025_12_01")
        XCTAssertEqual(parsed.metadata.nrDatabaseVersion, "nr_2025_12_01")
        XCTAssertEqual(parsed.rows.count, 3)

        let sarsCoV2 = try XCTUnwrap(parsed.rows.first { $0.taxId == 2697049 })
        XCTAssertEqual(sarsCoV2.name, "Severe acute respiratory syndrome coronavirus 2")
        XCTAssertEqual(sarsCoV2.rank, "species")
        XCTAssertEqual(sarsCoV2.ntReadCount, 42)
        XCTAssertEqual(sarsCoV2.ntRpm, 35000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sarsCoV2.ntPercentIdentity), 97.8, accuracy: 0.001)
        XCTAssertEqual(sarsCoV2.ntAlignmentLength, 151)
        XCTAssertEqual(try XCTUnwrap(sarsCoV2.ntEValue), 2e-50, accuracy: 1e-60)
        XCTAssertEqual(sarsCoV2.nrReadCount, 5)
    }

    func testConvertsTaxonReportToClassificationResult() throws {
        let fixture = fixtureURL("minimal_taxon_report.tsv")
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("czid-converter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let converted = try CzIdDataConverter.convertTaxonReport(
            at: fixture,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(converted.result.config.databaseName, "CZ-ID")
        XCTAssertEqual(converted.result.config.databaseVersion, "nt=nt_2025_12_01; nr=nr_2025_12_01")
        XCTAssertEqual(converted.result.toolVersion, "8.4")
        XCTAssertEqual(converted.result.tree.totalReads, 1200)
        XCTAssertEqual(converted.result.tree.node(taxId: 2697049)?.readsDirect, 42)
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.result.reportURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.result.outputURL.path))

        let manifest = try XCTUnwrap(converted.manifest)
        XCTAssertEqual(manifest.sampleName, "Sample-CZ-001")
        XCTAssertEqual(manifest.sourceFiles.map(\.lastPathComponent), ["minimal_taxon_report.tsv"])
    }

    // The taxonomy table's Sample column reads the recorded
    // `sampleDisplayName` and otherwise falls back to the input file's stem.
    // The converter recorded no name, so every CZ-ID import showed the copied
    // payload's stem, "classification.czid", instead of the CZ-ID sample.
    func testConvertedResultRecordsTheSampleNameForDisplay() throws {
        let fixture = fixtureURL("minimal_taxon_report.tsv")
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("czid-sample-name-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let converted = try CzIdDataConverter.convertTaxonReport(
            at: fixture,
            outputDirectory: outputDirectory,
            sourceInputURL: fixture
        )
        XCTAssertEqual(converted.result.config.sampleDisplayName, "Sample-CZ-001")
        let reloaded = try ClassificationResult.load(from: outputDirectory)
        XCTAssertEqual(reloaded.config.sampleDisplayName, "Sample-CZ-001")

        let renamedDirectory = outputDirectory.appendingPathComponent("renamed", isDirectory: true)
        let renamed = try CzIdDataConverter.convertTaxonReport(
            at: fixture,
            outputDirectory: renamedDirectory,
            sampleNameOverride: "Patient-7"
        )
        XCTAssertEqual(renamed.result.config.sampleDisplayName, "Patient-7")
    }

    // MARK: - CZ-ID's own taxon reports (CZID-REAL-EXPORT-FORMAT, S1)

    /// The kreport of `Tests/Fixtures/czid/sample_report.csv`, which has czid-web's `report_csv` shape: comma CSV,
    /// the 35 short-read columns, a numeric `tax_level` (2 genus, 1 species), `nt_count` and `nt_rpm`. A genus row's
    /// count is its clade count, so the genus direct count is what its species leave. The file has no root row, so
    /// the root is the total that `nt_count` / `nt_rpm` gives (1790 / 895.0 per million = 2,000,000).
    static let reportTableKreport = [
        "100.00\t2000000\t1997365\tR\t1\troot",
        "0.09\t1790\t60\tG\t1279\t  Staphylococcus",
        "0.08\t1520\t1520\tS\t1280\t    Staphylococcus aureus",
        "0.01\t210\t210\tS\t1282\t    Staphylococcus epidermidis",
        "0.04\t845\t5\tG\t694002\t  Betacoronavirus",
        "0.04\t840\t840\tS\t2697049\t    Severe acute respiratory syndrome coronavirus 2",
    ]

    func testReportTableCSVGivesCladeCountsAndTheRootFromRPM() throws {
        let root = try TestTempDirectory.make(prefix: "czid-report-csv")
        defer { TestTempDirectory.cleanup(root) }

        let converted = try CzIdDataConverter.convertTaxonReport(
            at: sharedFixtureURL("sample_report.csv"),
            outputDirectory: root.appendingPathComponent("imported", isDirectory: true)
        )

        XCTAssertEqual(try kreportLines(converted.result.reportURL), Self.reportTableKreport)
        XCTAssertEqual(converted.result.tree.totalReads, 2_000_000)
        XCTAssertEqual(converted.parsed.rows.map(\.rank), ["genus", "species", "species", "genus", "species"])
        XCTAssertEqual(converted.parsed.rows.map(\.nrReadCount), [1550, 1310, 180, 702, 700])
    }

    func testTabCopyOfTheReportTableGivesTheSameKreport() throws {
        let root = try TestTempDirectory.make(prefix: "czid-report-tsv")
        defer { TestTempDirectory.cleanup(root) }

        let converted = try CzIdDataConverter.convertTaxonReport(
            at: sharedFixtureURL("sample_report.tsv"),
            outputDirectory: root.appendingPathComponent("imported", isDirectory: true)
        )

        XCTAssertEqual(try kreportLines(converted.result.reportURL), Self.reportTableKreport)
    }

    /// czid-web's 25 long-read (Nanopore) columns have `nt_count` and `nr_count` but no rPM column, so the root is
    /// the sum of the genus clades.
    func testLongReadReportTableParsesItsCounts() throws {
        let root = try TestTempDirectory.make(prefix: "czid-report-long-read")
        defer { TestTempDirectory.cleanup(root) }
        let header = "tax_id,tax_level,genus_tax_id,name,common_name,category,is_phage,nt_bpm,nt_base_count,nt_count,"
            + "nt_contigs,nt_contig_b,nt_percent_identity,nt_alignment_length,nt_e_value,nr_bpm,nr_base_count,nr_count,"
            + "nr_contigs,nr_contig_b,nr_percent_identity,nr_alignment_length,nr_e_value,species_tax_ids,known_pathogen"
        let rows = [
            "1279,2,1279,Staphylococcus,,bacteria,0,447500.0,895000,1790,0,0,98.9,502.0,10^-62.4,387500.0,775000,1550,0,0,96.4,160.0,10^-25.1,\"[1280, 1282]\",1",
            "1280,1,1279,Staphylococcus aureus,,bacteria,0,380000.0,760000,1520,0,0,98.9,502.0,10^-65.0,327500.0,655000,1310,0,0,96.4,160.0,10^-26.3,,1",
            "1282,1,1279,Staphylococcus epidermidis,,bacteria,0,52500.0,105000,210,0,0,98.9,502.0,10^-55.2,45000.0,90000,180,0,0,96.4,160.0,10^-22.8,,0",
            "694002,2,694002,Betacoronavirus,,viruses,0,211250.0,422500,845,0,0,98.9,502.0,10^-70.1,175500.0,351000,702,0,0,96.4,160.0,10^-28.0,[2697049],1",
            "2697049,1,694002,Severe acute respiratory syndrome coronavirus 2,SARS-CoV-2,viruses,0,210000.0,420000,840,0,0,98.9,502.0,10^-70.3,175000.0,350000,700,0,0,96.4,160.0,10^-28.1,,1",
        ]
        let reportURL = root.appendingPathComponent("long_read_report.csv")
        try ([header] + rows).joined(separator: "\n").appending("\n").write(to: reportURL, atomically: true, encoding: .utf8)

        let parsed = try CzIdDataConverter.parseTaxonReport(at: reportURL)
        XCTAssertEqual(parsed.rows.map(\.ntReadCount), [1790, 1520, 210, 845, 840])
        XCTAssertEqual(parsed.rows.map(\.nrReadCount), [1550, 1310, 180, 702, 700])
        XCTAssertEqual(parsed.rows.map(\.rank), ["genus", "species", "species", "genus", "species"])
        XCTAssertEqual(CzIdDataConverter.kreportText(from: parsed.rows).components(separatedBy: "\n").dropLast(), [
            "100.00\t2635\t0\tR\t1\troot",
            "67.93\t1790\t60\tG\t1279\t  Staphylococcus",
            "57.69\t1520\t1520\tS\t1280\t    Staphylococcus aureus",
            "7.97\t210\t210\tS\t1282\t    Staphylococcus epidermidis",
            "32.07\t845\t5\tG\t694002\t  Betacoronavirus",
            "31.88\t840\t840\tS\t2697049\t    Severe acute respiratory syndrome coronavirus 2",
        ])
    }

    /// A report the converter cannot count is refused in Sol's words (FIX-CZID Z1, Z2 and Z9), never imported with 0
    /// reads.
    func testReportsThatCannotBeCountedAreRefused() throws {
        let root = try TestTempDirectory.make(prefix: "czid-report-refusals")
        defer { TestTempDirectory.cleanup(root) }

        XCTAssertEqual(
            try refusal(in: root, "no-counts.csv", "tax_id,tax_level,genus_tax_id,name,nt_rpm\n1279,2,1279,Staphylococcus,895.0\n"),
            "no-counts.csv has no read count column (nt_count or nr_count), so counts cannot be assigned to taxa. Nothing was imported."
        )
        XCTAssertEqual(
            try refusal(in: root, "no-tax-id.csv", "tax_level,genus_tax_id,name,nt_rpm,nt_count\n2,1279,Staphylococcus,895.0,1790\n"),
            "no-tax-id.csv is missing the tax_id column required for CZ-ID taxon reports. Nothing was imported."
        )
        XCTAssertEqual(
            try refusal(in: root, "no-name.csv", "tax_id,tax_level,genus_tax_id,nt_rpm,nt_count\n1279,2,1279,895.0,1790\n"),
            "no-name.csv is missing the name column required for CZ-ID taxon reports. Nothing was imported."
        )
        XCTAssertEqual(
            try refusal(
                in: root,
                "empty-name.csv",
                "tax_id,tax_level,genus_tax_id,name,nt_rpm,nt_count\n1279,2,1279,Staphylococcus,895.0,1790\n1280,1,1279,,760.0,1520\n"
            ),
            "Row 3 of empty-name.csv has no name value. Nothing was imported."
        )
    }

    /// A comma report with CRLF line ends, a doubled quote and a quoted comma reads as RFC 4180 says (FIX-CZID SWIFT SF1).
    func testCommaReportReadsCRLFLineEndsDoubledQuotesAndQuotedCommas() throws {
        let root = try TestTempDirectory.make(prefix: "czid-report-rfc4180")
        defer { TestTempDirectory.cleanup(root) }
        let reportURL = root.appendingPathComponent("rfc4180_report.csv")
        let text = "tax_id,tax_level,genus_tax_id,name,nt_rpm,nt_count\r\n"
            + "1279,2,1279,\"Staphylococcus \"\"Group A\"\", strain 1\",895.0,1790\r\n"
            + "1280,1,1279,Staphylococcus aureus,760.0,1520\r\n"
        try text.write(to: reportURL, atomically: true, encoding: .utf8)

        let parsed = try CzIdDataConverter.parseTaxonReport(at: reportURL)

        XCTAssertEqual(parsed.rows.map(\.name), ["Staphylococcus \"Group A\", strain 1", "Staphylococcus aureus"])
        XCTAssertEqual(parsed.rows.map(\.ntReadCount), [1790, 1520])
        XCTAssertEqual(parsed.rows.map(\.rank), ["genus", "species"])
    }

    /// A quoted field that runs past its line is refused in the words of a report that cannot be read (FIX-CZID SWIFT SF1).
    func testQuotedFieldThatRunsPastItsLineIsRefused() throws {
        let root = try TestTempDirectory.make(prefix: "czid-report-open-quote")
        defer { TestTempDirectory.cleanup(root) }
        let url = root.appendingPathComponent("open-quote.csv")

        XCTAssertEqual(
            try refusal(in: root, "open-quote.csv", "tax_id,tax_level,genus_tax_id,name,nt_count\n1279,2,1279,\"Staphylococcus\nGroup A\",1790\n"),
            "No parseable CZ-ID taxon report was found in \(url.path)"
        )
    }

    /// A named taxon with no rank, or a rank word the converter does not know, is a no-rank taxon (Kraken's `-`)
    /// that keeps its reads. It was written as `U`, and the kreport parser keeps one unclassified line, so every such
    /// row but the last lost its reads and the total counted them again.
    func testRowsWithNoRankKeepTheirReadsInTheTree() throws {
        let root = try TestTempDirectory.make(prefix: "czid-report-no-rank")
        defer { TestTempDirectory.cleanup(root) }
        let reportURL = root.appendingPathComponent("no_rank_report.tsv")
        try """
        sample_name\ttax_id\ttaxon_name\trank\tnt_read_count\tnt_rpm
        Sample-CZ-001\t1\troot\troot\t1200\t1000000
        Sample-CZ-001\t10239\tViruses\tno rank\t88\t73333
        Sample-CZ-001\t2697049\tSevere acute respiratory syndrome coronavirus 2\t\t42\t35000

        """.write(to: reportURL, atomically: true, encoding: .utf8)

        let converted = try CzIdDataConverter.convertTaxonReport(
            at: reportURL,
            outputDirectory: root.appendingPathComponent("imported", isDirectory: true)
        )

        XCTAssertEqual(try kreportLines(converted.result.reportURL), [
            "100.00\t1200\t1200\tR\t1\troot",
            "7.33\t88\t88\t-\t10239\t  Viruses",
            "3.50\t42\t42\t-\t2697049\t  Severe acute respiratory syndrome coronavirus 2",
        ])
        XCTAssertEqual(converted.result.tree.node(taxId: 10239)?.readsClade, 88)
        XCTAssertEqual(converted.result.tree.node(taxId: 2697049)?.readsClade, 42)
        XCTAssertEqual(converted.result.tree.totalReads, 1200)
        XCTAssertEqual(converted.result.tree.unclassifiedReads, 0)
    }

    /// Every CZ-ID fixture in Tests/ still parses.
    func testEveryCzIdFixtureParses() throws {
        for name in ["minimal_taxon_report.tsv", "sample_report.csv", "sample_report.tsv"] {
            XCTAssertEqual(try CzIdDataConverter.parseTaxonReport(at: sharedFixtureURL(name)).rows.isEmpty, false, name)
        }
        XCTAssertEqual(try CzIdDataConverter.parseTaxonReport(at: fixtureURL("minimal_taxon_report.tsv")).rows.count, 3)
    }

    private func refusal(in root: URL, _ name: String, _ text: String) throws -> String? {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try CzIdDataConverter.parseTaxonReport(at: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func kreportLines(_ url: URL) throws -> [String] {
        Array(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").dropLast())
    }

    /// `Tests/Fixtures/czid`, which the CLI suites share.
    private func sharedFixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/czid", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/CzId", isDirectory: true)
            .appendingPathComponent(name)
    }
}
