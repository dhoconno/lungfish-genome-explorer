// TaxTriageExportPinTests.swift - Pins the three TaxTriage viewer exports at their base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.32 M1 (QA 1). The results CSV or TSV is written by `TaxTriageResultViewController` itself, and
// until lane 12.32 A4 and A5 so were the organism matrix and the batch report, which now run `taxtriage export` and are
// pinned by TaxTriageExportCLIGUIParityReplayTests. Each pin sets the view state a user can set (the Sample Filter,
// the organism search and the flat table's sort) and pins the bytes and the provenance record the writer produces
// with it. Every production TaxTriage result opens through `configureFromDatabase`, so `tableMode` is `batchGroup`
// in every record below. No Sources edit stands behind these pins, and they pass at the lane base.

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit

@MainActor
final class TaxTriageExportPinTests: XCTestCase {

    // MARK: - Unique Reads of a database that stores NULL (A6, F3)

    /// F3 (BIO ruling on 12.32). A production database can store NULL `unique_reads`. The results export writes the
    /// stored value, normalized as the page snapshot normalizes it, and an empty cell for NULL, and opens no BAM. The
    /// loader and the builder the `taxtriage export results` leaf uses give the cells of the viewer's flat table.
    func testResultsExportLeavesANullUniqueReadsCellEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageExportPin-null-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try TaxTriageDatabase.create(
            at: root.appendingPathComponent(TaxTriageExportLoader.databaseFileName),
            rows: [
                Self.rowStoringUniqueReads("S1", "OrgA", 1, reads: 50, uniqueReads: 40),
                Self.rowStoringUniqueReads("S1", "OrgB", 2, reads: 30, uniqueReads: nil),
            ],
            metadata: ["tool": "taxtriage"]
        )
        let source = try TaxTriageExportLoader.load(resultURL: root, samples: [], searchText: nil)
        let text = TaxTriageResultsExport.buildDelimitedExport(
            rows: source.metrics,
            totalReadsByKey: source.totalReadsByKey,
            uniqueReadsByKey: source.uniqueReadsByKey,
            contaminationRiskOrganismKeys: source.contaminationRiskOrganismKeys,
            metadataHeaders: [],
            metadataValuesBySample: [:],
            separator: "\t"
        )
        let uniqueColumn = 4
        let fields = text.split(separator: "\n").dropFirst()
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(fields.first { $0[1] == "OrgA" }?[uniqueColumn], "40")
        XCTAssertEqual(fields.first { $0[1] == "OrgB" }?[uniqueColumn], "")
        XCTAssertNil(source.uniqueReadsByKey["S1\tOrgB"], "a NULL fills no key, as the page snapshot leaves it")
    }

    private static func rowStoringUniqueReads(
        _ sample: String, _ organism: String, _ taxId: Int, reads: Int, uniqueReads: Int?
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: taxId, status: nil, tassScore: 0.5,
            readsAligned: reads, uniqueReads: uniqueReads, pctReads: nil, pctAlignedReads: nil,
            coverageBreadth: 50, meanCoverage: nil, meanDepth: nil, confidence: "High",
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
            mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil,
            isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil, bamPath: nil,
            bamIndexPath: nil, primaryAccession: "NC_\(taxId)", accessionLength: 1000
        )
    }

    // MARK: - Builders for a result of one sample (A4 and A5)

    /// The matrix and the report of a result of one sample are the builders' output for the rows the view loaded. The
    /// two-sample cases, the sample selection, the search and the records are held by the parity class
    /// (`TaxTriageExportCLIGUIParityReplayTests`) and the leaf tests (`TaxTriageExportCommandsTests`).
    func testSingleSampleMatrixHasOneSampleColumn() throws {
        let fixture = try Fixture(samples: ["sample-1"])
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)

        let csv = TaxTriageBatchExporter.generateOrganismMatrixCSV(
            metrics: vc.testBatchFlatTableView.displayedRows, sampleIds: ["sample-1"], negativeControlSampleIds: []
        )
        XCTAssertEqual(csv, [
            "Organism,Mean TASS,Samples Detected,Contamination Risk,sample-1",
            "Alpha virus,0.9100,1/1,No,0.9100",
            "Beta virus,0.7600,1/1,No,0.7600",
            "\"Delta, \"\"quoted\"\" virus\",0.6000,1/1,No,0.6000",
        ].joined(separator: "\n") + "\n")
    }

    func testSingleSampleReportHasNoControlSections() throws {
        let fixture = try Fixture(samples: ["sample-1"])
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        let result = try XCTUnwrap(vc.testResult)

        let report = TaxTriageBatchExporter.generateSummaryReport(
            result: result, config: result.config, metrics: vc.testBatchFlatTableView.displayedRows, sampleIds: ["sample-1"]
        )
        XCTAssertTrue(report.contains("Samples: 1"), report)
        XCTAssertTrue(report.contains("sample-1: 3 organisms (1 high confidence)"), report)
        XCTAssertTrue(report.contains("No organisms detected in multiple samples."), report)
        XCTAssertTrue(report.contains("Alpha virus: mean TASS=0.910, 1 sample(s)"), report)
        XCTAssertFalse(report.contains("Negative Controls:"), report)
        XCTAssertFalse(report.contains("--- Contamination Risk Organisms ---"), report)
    }

    // MARK: - Fixture

    /// Five rows over two samples. `sample-2` can be the negative control. One organism name holds a comma and quotes.
    private struct Fixture {
        let root: URL
        let database: TaxTriageDatabase
        let samples: [String]
        let config: TaxTriageConfig

        static let header = "Sample\tOrganism\tTASS Score\tReads\tUnique Reads\tCoverage\tConfidence\tTax ID\tRank\tAbundance\tContamination Risk"
        static let delta = "Delta, \"quoted\" virus"

        init(samples: [String], negativeControl: String? = nil) throws {
            let fm = FileManager.default
            let rootURL = fm.temporaryDirectory
                .appendingPathComponent("TaxTriageExportPin-\(UUID().uuidString)", isDirectory: true)
            root = rootURL
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            self.samples = samples
            let all = [
                Self.row("sample-1", "Alpha virus", 1001, 0.91, 42, "High"),
                Self.row("sample-1", "Beta virus", 1002, 0.76, 24, "High"),
                Self.row("sample-1", Self.delta, 3001, 0.60, 6, "Medium"),
                Self.row("sample-2", "Gamma virus", 2001, 0.50, 12, "Medium"),
                Self.row("sample-2", "Alpha virus", 1001, 0.20, 3, "Low"),
            ]
            database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: all.filter { samples.contains($0.sample) },
                metadata: ["tool": "taxtriage"]
            )
            config = TaxTriageConfig(
                samples: samples.map {
                    TaxTriageSample(
                        sampleId: $0,
                        fastq1: rootURL.appendingPathComponent("\($0).fastq.gz"),
                        isNegativeControl: $0 == negativeControl
                    )
                },
                outputDirectory: root
            )
            let result = TaxTriageResult(config: config, runtime: 61, exitCode: 0, outputDirectory: root)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(result).write(to: root.appendingPathComponent("taxtriage-result.json"))
            // A manifest beside the database. No export reads it, so no record names it.
            try Data("{}".utf8).write(to: root.appendingPathComponent(TaxTriageBatchManifest.filename))
        }

        var rowCount: Int { samples.reduce(0) { $0 + ($1 == "sample-1" ? 3 : 2) } }
        var databasePath: String { root.appendingPathComponent("taxtriage.sqlite").path }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        private static func row(
            _ sample: String, _ organism: String, _ taxId: Int, _ tass: Double, _ reads: Int, _ confidence: String
        ) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: sample, organism: organism, taxId: taxId, status: nil, tassScore: tass,
                readsAligned: reads, uniqueReads: reads / 2, pctReads: nil, pctAlignedReads: nil,
                coverageBreadth: 50, meanCoverage: nil, meanDepth: nil, confidence: confidence,
                k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
                mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
                k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil,
                isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
                isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil, bamPath: nil,
                bamIndexPath: nil, primaryAccession: "NC_\(taxId)", accessionLength: 1000
            )
        }
    }

    // MARK: - Helpers

    private func makeController(_ fixture: Fixture) -> TaxTriageResultViewController {
        let vc = TaxTriageResultViewController()
        _ = vc.view
        vc.configureFromDatabase(fixture.database, resultURL: fixture.root)
        waitForRows(vc) { $0.count == fixture.rowCount }
        return vc
    }

    private func waitForRows(
        _ vc: TaxTriageResultViewController,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: ([TaxTriageMetric]) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(60)
        while !condition(vc.testBatchFlatTableView.displayedRows) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(vc.testBatchFlatTableView.displayedRows), "rows did not load", file: file, line: line)
    }
}
