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

    // MARK: - Results CSV and TSV (A6)

    private static let resultsKeys = [
        "metadataColumns", "organismSearchText", "rowCount", "sampleIds", "selectedSamples", "sortDescriptors",
        "tableMode",
    ]

    /// Both samples ticked, the search "alpha" and the reads column sorted ascending. The negative control marks every
    /// row of an organism the control holds.
    func testBatchTSVFollowsTheSearchAndTheSortAndRecordsTheView() throws {
        let fixture = try Fixture(samples: ["sample-1", "sample-2"], negativeControl: "sample-2")
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        waitForContaminationFlags(vc)
        search("alpha", in: vc) { $0.count == 2 }
        sort("tt_reads", ascending: true, in: vc)

        let output = fixture.root.appendingPathComponent("results.tsv")
        try vc.writeDelimitedResults(separator: "\t", fileExtension: "tsv", to: output)
        XCTAssertEqual(try text(output), [
            Fixture.header,
            "sample-2\tAlpha virus\t0.2000\t3\t1\t50.00\tLow\t1001\t\t\tyes",
            "sample-1\tAlpha virus\t0.9100\t42\t21\t50.00\tHigh\t1001\t\t\tyes",
        ].joined(separator: "\n") + "\n")

        let resolved = try assertRecord(
            output, fixture: fixture, workflow: "lungfish app taxtriage results export",
            argvTail: ["export-taxtriage-results", "--format", "tsv"], format: "tsv", defaultFormat: "tsv",
            resolvedKeys: Self.resultsKeys
        )
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 2)
        XCTAssertEqual(resolved["organismSearchText"]?.stringValue, "alpha")
        XCTAssertEqual(Self.sortKeys(resolved["sortDescriptors"]), ["tt_reads:ascending"])
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-1", "sample-2"])
        XCTAssertEqual(resolved["sampleIds"]?.arrayValue?.compactMap(\.stringValue), ["sample-1", "sample-2"])
        XCTAssertEqual(resolved["tableMode"]?.stringValue, "batchGroup")
        XCTAssertEqual(resolved["metadataColumns"]?.arrayValue?.count, 0)
    }

    /// One sample ticked in the Sample Filter, the TASS column sorted ascending, written as CSV. The writer records the
    /// default format `tsv` whatever format the user chose, and the comma and quotes of one organism are escaped.
    func testBatchCSVOfOneSelectedSampleQuotesTheFieldsTheWriterEscapes() throws {
        let fixture = try Fixture(samples: ["sample-1", "sample-2"])
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        selectSegment(1, in: vc) { $0.count == 3 && $0.allSatisfy { $0.sample == "sample-1" } }
        sort("tt_tassScore", ascending: true, in: vc)

        let output = fixture.root.appendingPathComponent("results.csv")
        try vc.writeDelimitedResults(separator: ",", fileExtension: "csv", to: output)
        XCTAssertEqual(try text(output), [
            Fixture.header.replacingOccurrences(of: "\t", with: ","),
            "sample-1,\"Delta, \"\"quoted\"\" virus\",0.6000,6,3,50.00,Medium,3001,,,",
            "sample-1,Beta virus,0.7600,24,12,50.00,High,1002,,,",
            "sample-1,Alpha virus,0.9100,42,21,50.00,High,1001,,,",
        ].joined(separator: "\n") + "\n")

        let resolved = try assertRecord(
            output, fixture: fixture, workflow: "lungfish app taxtriage results export",
            argvTail: ["export-taxtriage-results", "--format", "csv"], format: "csv", defaultFormat: "tsv",
            resolvedKeys: Self.resultsKeys
        )
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 3)
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-1"])
        XCTAssertEqual(resolved["organismSearchText"]?.stringValue, "")
        XCTAssertEqual(Self.sortKeys(resolved["sortDescriptors"]), ["tt_tassScore:ascending"])
    }

    /// A result of one sample names that sample as the selected sample, and the name column sorts descending.
    func testSingleSampleTSVNamesTheOnlySampleAsTheSelectedSample() throws {
        let fixture = try Fixture(samples: ["sample-1"])
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        sort("tt_organism", ascending: false, in: vc)

        let output = fixture.root.appendingPathComponent("results.tsv")
        try vc.writeDelimitedResults(separator: "\t", fileExtension: "tsv", to: output)
        XCTAssertEqual(try text(output), [
            Fixture.header,
            "sample-1\tDelta, \"quoted\" virus\t0.6000\t6\t3\t50.00\tMedium\t3001\t\t\t",
            "sample-1\tBeta virus\t0.7600\t24\t12\t50.00\tHigh\t1002\t\t\t",
            "sample-1\tAlpha virus\t0.9100\t42\t21\t50.00\tHigh\t1001\t\t\t",
        ].joined(separator: "\n") + "\n")

        let resolved = try assertRecord(
            output, fixture: fixture, workflow: "lungfish app taxtriage results export",
            argvTail: ["export-taxtriage-results", "--format", "tsv"], format: "tsv", defaultFormat: "tsv",
            resolvedKeys: Self.resultsKeys
        )
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 3)
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-1"])
        XCTAssertEqual(Self.sortKeys(resolved["sortDescriptors"]), ["tt_organism:descending"])
    }

    /// A shown metadata column appends each row's own sample value, and the record lists the column.
    func testShownMetadataColumnAppendsEachRowsOwnSampleValue() throws {
        let fixture = try Fixture(samples: ["sample-1", "sample-2"])
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)
        let store = try SampleMetadataStore(
            csvData: Data("Sample\tGroup\nsample-1\tcase\nsample-2\tcontrol\n".utf8),
            knownSampleIds: ["sample-1", "sample-2"]
        )
        let columns = vc.testBatchFlatTableView.metadataColumns
        columns.visibleColumns = ["Group"]
        columns.update(store: store, sampleId: nil)
        sort("tt_reads", ascending: true, in: vc)

        let output = fixture.root.appendingPathComponent("results.tsv")
        try vc.writeDelimitedResults(separator: "\t", fileExtension: "tsv", to: output)
        XCTAssertEqual(try text(output), [
            Fixture.header + "\tGroup",
            "sample-2\tAlpha virus\t0.2000\t3\t1\t50.00\tLow\t1001\t\t\t\tcontrol",
            "sample-1\tDelta, \"quoted\" virus\t0.6000\t6\t3\t50.00\tMedium\t3001\t\t\t\tcase",
            "sample-2\tGamma virus\t0.5000\t12\t6\t50.00\tMedium\t2001\t\t\t\tcontrol",
            "sample-1\tBeta virus\t0.7600\t24\t12\t50.00\tHigh\t1002\t\t\t\tcase",
            "sample-1\tAlpha virus\t0.9100\t42\t21\t50.00\tHigh\t1001\t\t\t\tcase",
        ].joined(separator: "\n") + "\n")

        let resolved = try assertRecord(
            output, fixture: fixture, workflow: "lungfish app taxtriage results export",
            argvTail: ["export-taxtriage-results", "--format", "tsv"], format: "tsv", defaultFormat: "tsv",
            resolvedKeys: Self.resultsKeys
        )
        XCTAssertEqual(resolved["metadataColumns"]?.arrayValue?.compactMap(\.stringValue), ["Group"])
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 5)
    }

    /// F7-1 (BIO ruling on 12.32). The record holds the sample set the rows were cut to and no Sample Filter segment.
    /// `selectedSampleIndex` and `selectedSampleId` named view state the export never applies, so no key holds them
    /// and `selectedSamples` follows the picker. In database mode the segment is the picker, so the ruling's
    /// byte-equal check cannot hold. The check here is that the file's samples equal the recorded sample set.
    func testResultsRecordHoldsTheAppliedSampleSetAndNoSegment() throws {
        let fixture = try Fixture(samples: ["sample-1", "sample-2"])
        defer { fixture.cleanUp() }
        let vc = makeController(fixture)

        for (segment, applied) in [(0, ["sample-1", "sample-2"]), (1, ["sample-1"]), (2, ["sample-2"])] {
            selectSegment(segment, in: vc) { Set($0.compactMap(\.sample)) == Set(applied) }
            let output = fixture.root.appendingPathComponent("segment-\(segment).tsv")
            try vc.writeDelimitedResults(separator: "\t", fileExtension: "tsv", to: output)
            let resolved = try assertRecord(
                output, fixture: fixture, workflow: "lungfish app taxtriage results export",
                argvTail: ["export-taxtriage-results", "--format", "tsv"], format: "tsv", defaultFormat: "tsv",
                resolvedKeys: Self.resultsKeys
            )
            XCTAssertNil(resolved["selectedSampleIndex"], "segment \(segment)")
            XCTAssertNil(resolved["selectedSampleId"], "segment \(segment)")
            XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), applied)
            let fileSamples = try text(output).split(separator: "\n").dropFirst()
                .compactMap { $0.split(separator: "\t").first.map(String.init) }
            XCTAssertEqual(Set(fileSamples), Set(applied), "segment \(segment)")
        }
    }

    /// F7-2 (BIO ruling on 12.32). The results export names the sample metadata table and its edit journal, each with
    /// its digest, when it writes a metadata column and none otherwise. The matrix and the report never name them.
    func testMetadataFilesAreInputsOfTheResultsExportOnly() throws {
        let fixture = try Fixture(samples: ["sample-1", "sample-2"])
        defer { fixture.cleanUp() }
        let metadataFolder = fixture.root.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        try Data("Sample\tGroup\nsample-1\tcase\nsample-2\tcontrol\n".utf8)
            .write(to: metadataFolder.appendingPathComponent("sample_metadata.tsv"))
        try Data("[]".utf8).write(to: metadataFolder.appendingPathComponent("sample_metadata_edits.json"))
        let vc = makeController(fixture)
        let store = try XCTUnwrap(SampleMetadataStore.load(from: fixture.root, knownSampleIds: ["sample-1", "sample-2"]))
        let columns = vc.testBatchFlatTableView.metadataColumns
        columns.visibleColumns = ["Group"]
        columns.update(store: store, sampleId: nil)
        func inputs(_ url: URL) throws -> [(name: String, digest: String?)] {
            let envelope = try XCTUnwrap(
                ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: url))
            )
            return envelope.files.filter { $0.role == .input }
                .map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.checksumSHA256) }
                .sorted { $0.name < $1.name }
        }
        let shown = fixture.root.appendingPathComponent("shown.tsv")
        try vc.writeDelimitedResults(separator: "\t", fileExtension: "tsv", to: shown)
        let shownInputs = try inputs(shown)
        XCTAssertEqual(
            shownInputs.map(\.name),
            ["sample_metadata.tsv", "sample_metadata_edits.json", "taxtriage-result.json", "taxtriage.sqlite"]
        )
        XCTAssertTrue(shownInputs.allSatisfy { $0.digest != nil })

        // The matrix and report leaves name only the database and the sidecar, with these metadata files on disk
        // (TaxTriageExportCLIGUIParityReplayTests).

        columns.visibleColumns = []
        let hidden = fixture.root.appendingPathComponent("hidden.tsv")
        try vc.writeDelimitedResults(separator: "\t", fileExtension: "tsv", to: hidden)
        XCTAssertEqual(try inputs(hidden).map(\.name), ["taxtriage-result.json", "taxtriage.sqlite"])
    }

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

    private func waitForContaminationFlags(_ vc: TaxTriageResultViewController) {
        let table = vc.testBatchFlatTableView
        let deadline = Date().addingTimeInterval(30)
        while table.contaminationRiskOrganismKeys.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(table.contaminationRiskOrganismKeys.isEmpty, "negative-control flags did not load")
    }

    /// The Sample Filter segment of a two-sample result, where segment 0 is All Samples.
    private func selectSegment(
        _ segment: Int,
        in vc: TaxTriageResultViewController,
        until condition: ([TaxTriageMetric]) -> Bool
    ) {
        vc.testSampleFilterControl.selectedSegment = segment
        _ = vc.testSampleFilterControl.sendAction(vc.testSampleFilterControl.action, to: vc.testSampleFilterControl.target)
        waitForRows(vc, until: condition)
    }

    /// Types `text` in the organism search field and waits for the debounced reload.
    private func search(
        _ text: String,
        in vc: TaxTriageResultViewController,
        until condition: ([TaxTriageMetric]) -> Bool
    ) {
        let field = vc.testingOrganismSearchField
        field.stringValue = text
        _ = field.sendAction(field.action, to: field.target)
        waitForRows(vc, until: condition)
    }

    private func sort(_ key: String, ascending: Bool, in vc: TaxTriageResultViewController) {
        vc.testBatchFlatTableView.columnHeaderFilterMenu(sortByKey: key, ascending: ascending)
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static func sortKeys(_ value: ParameterValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item in
            guard case .dictionary(let entries) = item,
                  case .string(let key)? = entries["key"],
                  case .boolean(let ascending)? = entries["ascending"] else { return nil }
            return "\(key):\(ascending ? "ascending" : "descending")"
        }
    }

    /// Pins the identity fields every writer shares, and returns the `resolved` part for the caller's own checks.
    @discardableResult
    private func assertRecord(
        _ outputURL: URL,
        fixture: Fixture,
        workflow: String,
        argvTail: [String],
        format: String,
        defaultFormat: String,
        resolvedKeys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: ParameterValue] {
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)),
            file: file, line: line
        )
        let argv = ["Lungfish.app"] + argvTail + ["--output", outputURL.path]
        XCTAssertEqual(envelope.workflowName, workflow, file: file, line: line)
        XCTAssertEqual(envelope.toolName, "Lungfish.app", file: file, line: line)
        XCTAssertEqual(envelope.tool.name, "Lungfish.app", file: file, line: line)
        XCTAssertEqual(envelope.tool.kind, "gui", file: file, line: line)
        XCTAssertEqual(envelope.argv, argv, file: file, line: line)
        XCTAssertEqual(envelope.durableReplayArgv, argv, file: file, line: line)
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["format", "outputPath"], file: file, line: line)
        XCTAssertEqual(envelope.options.explicit["format"]?.stringValue, format, file: file, line: line)
        XCTAssertEqual(envelope.options.defaults.keys.sorted(), ["format"], file: file, line: line)
        XCTAssertEqual(envelope.options.defaults["format"]?.stringValue, defaultFormat, file: file, line: line)
        XCTAssertEqual(envelope.options.resolvedDefaults.keys.sorted(), resolvedKeys, file: file, line: line)
        XCTAssertEqual(envelope.output?.path, outputURL.path, file: file, line: line)
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: outputURL), file: file, line: line)
        // Inputs (BIO 6). The files the export reads and nothing else, which are the result database and the run's
        // sidecar (the negative controls and the report's run facts). Neither the batch manifest nor the result
        // folder is read. The base recorded the manifest and the whole folder (a directory with no digest) and not
        // the sidecar, so this pin fails at the base and the fix goes on the writer in its own commit.
        let sidecar = fixture.root.appendingPathComponent("taxtriage-result.json").path
        let paths = Set(envelope.files.map(\.path)).subtracting([outputURL.path])
        XCTAssertEqual(paths, [fixture.databasePath, sidecar], file: file, line: line)
        for input in [fixture.databasePath, sidecar] {
            let digest = envelope.files.first { $0.path == input }?.checksumSHA256
            XCTAssertEqual(digest, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: input)), file: file, line: line)
        }
        return envelope.options.resolvedDefaults
    }
}
