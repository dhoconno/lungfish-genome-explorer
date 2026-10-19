// TaxTriageResultsExportCommandTests.swift - lungfish-cli taxtriage export results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.32 A6. The leaf writes the results table of a TaxTriage result as the viewer's Export does, from
// the files of the result folder alone, and records the files it read. The parity class in
// Tests/LungfishAppTests/TaxTriageExportCLIGUIParityReplayTests.swift runs the app's table against it.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageResultsExportCommandTests: XCTestCase {
    private var root: URL!

    private static let header = "Sample\tOrganism\tTASS Score\tReads\tUnique Reads\tCoverage\tConfidence\t"
        + "Tax ID\tRank\tAbundance\tContamination Risk"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-results-leaf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Five rows over two samples, `sample-2` the negative control, the Delta row storing no Unique Reads, the run's
    /// sidecar and the sample metadata table with its edit journal.
    private func makeResult() throws -> URL {
        let result = root.appendingPathComponent("taxtriage-result", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        _ = try TaxTriageDatabase.create(
            at: result.appendingPathComponent(TaxTriageExportLoader.databaseFileName),
            rows: [
                Self.row("sample-1", "Alpha virus", 1001, 0.91, 42, "High"),
                Self.row("sample-1", "Beta virus", 1002, 0.76, 24, "High"),
                Self.row("sample-1", "Delta, \"quoted\" virus", 3001, 0.60, 6, "Medium", storesUniqueReads: false),
                Self.row("sample-2", "Gamma virus", 2001, 0.50, 12, "Medium"),
                Self.row("sample-2", "Alpha virus", 1001, 0.20, 3, "Low"),
            ],
            metadata: ["tool": "taxtriage"]
        )
        let config = TaxTriageConfig(
            samples: ["sample-1", "sample-2"].map {
                TaxTriageSample(
                    sampleId: $0,
                    fastq1: result.appendingPathComponent("\($0).fastq.gz"),
                    isNegativeControl: $0 == "sample-2"
                )
            },
            outputDirectory: result
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TaxTriageResult(config: config, runtime: 61, exitCode: 0, outputDirectory: result))
            .write(to: result.appendingPathComponent(TaxTriageExportLoader.sidecarFileName))
        let metadata = result.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("Sample\tGroup\nsample-1\tcase\nsample-2\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        try Data("[]".utf8).write(to: metadata.appendingPathComponent("sample_metadata_edits.json"))
        return result
    }

    private static func row(
        _ sample: String, _ organism: String, _ taxId: Int, _ tass: Double, _ reads: Int, _ confidence: String,
        storesUniqueReads: Bool = true
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: taxId, status: nil, tassScore: tass,
            readsAligned: reads, uniqueReads: storesUniqueReads ? reads / 2 : nil, pctReads: nil, pctAlignedReads: nil,
            coverageBreadth: 50, meanCoverage: nil, meanDepth: nil, confidence: confidence,
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
            mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil,
            isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil, bamPath: nil,
            bamIndexPath: nil, primaryAccession: "NC_\(taxId)", accessionLength: 1000
        )
    }

    private func run(_ arguments: [String]) throws -> ViewerExportLeafOutcome {
        try TaxTriageCommand.ExportResultsSubcommand.parse(arguments).export()
    }

    private func envelope(of output: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
    }

    private func inputNames(_ envelope: ProvenanceEnvelope) -> [String] {
        envelope.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
    }

    /// The arguments the view builds, whatever the view state, parse back to the invocation they came from.
    func testTheLeafParsesTheArgumentsTheViewBuilds() throws {
        let invocation = TaxTriageResultsExport.invocation(
            resultURL: URL(fileURLWithPath: "/tmp/lane 12.32/Project.lungfish/Analyses/taxtriage-batch", isDirectory: true),
            samples: ["sample-A", "sample B"],
            searchText: "beta virus",
            sortKeys: [
                ViewerExportSortKey(column: "tt_reads", ascending: false),
                ViewerExportSortKey(column: "metadata_Site Name", ascending: true),
            ],
            filters: ColumnFilterSet(
                filters: [ColumnFilter(columnId: "tt_reads", op: .greaterOrEqual, value: "10")],
                composition: .any
            ),
            metadataColumns: ["Group", "Site Name"],
            format: .csv,
            outputURL: URL(fileURLWithPath: "/tmp/lane 12.32/results, all.csv"),
            force: true
        )
        let command = try TaxTriageCommand.ExportResultsSubcommand.parse(
            Array(invocation.arguments().dropFirst(invocation.commandPath.count))
        )
        XCTAssertEqual(try command.invocation(), invocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample-A", "sample B"])
        XCTAssertEqual(command.search.text, "beta virus")
        XCTAssertEqual(command.sort.keys, invocation.state.sortKeys)
        XCTAssertEqual(command.filters.match, .any)
        XCTAssertEqual(command.metadataColumns.columns, ["Group", "Site Name"])
        XCTAssertEqual(command.format.format, .csv)
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
        XCTAssertEqual(
            try command.invocation().canonicalArgv().prefix(4).map { $0 },
            [CLICommandIdentity.executableName, "taxtriage", "export", "results"]
        )
    }

    /// Both samples sorted by reads. The Delta row stores no Unique Reads, so its cell is empty, and the organisms
    /// the negative control holds carry the contamination mark in every sample.
    func testTheLeafWritesTheTableAndTheFilesItReadAsInputs() throws {
        let result = try makeResult()
        let output = root.appendingPathComponent("results.tsv")
        let outcome = try run([
            result.path, "--output-format", "tsv", "--sort", "tt_reads:ascending", "--output", output.path,
        ])
        XCTAssertEqual(outcome.outputURL, output)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), [
            Self.header,
            "sample-2\tAlpha virus\t0.2000\t3\t1\t50.00\tLow\t1001\t\t\tyes",
            "sample-1\tDelta, \"quoted\" virus\t0.6000\t6\t\t50.00\tMedium\t3001\t\t\t",
            "sample-2\tGamma virus\t0.5000\t12\t6\t50.00\tMedium\t2001\t\t\tyes",
            "sample-1\tBeta virus\t0.7600\t24\t12\t50.00\tHigh\t1002\t\t\t",
            "sample-1\tAlpha virus\t0.9100\t42\t21\t50.00\tHigh\t1001\t\t\tyes",
        ].joined(separator: "\n") + "\n")

        let record = try envelope(of: output)
        XCTAssertEqual(record.workflowName, TaxTriageResultsExport.workflowName)
        XCTAssertEqual(record.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(record.tool.kind, "cli")
        XCTAssertEqual(inputNames(record), ["taxtriage-result.json", "taxtriage.sqlite"], "no metadata file without a column")
        XCTAssertTrue(record.files.filter { $0.role == .input }.allSatisfy { $0.checksumSHA256 != nil })
        XCTAssertEqual(record.options.explicit.keys.sorted(), ["outputFormat", "outputPath", "sortKeys"])
        let resolved = record.options.resolvedDefaults
        XCTAssertEqual(
            Set(resolved.keys),
            ["metadataColumns", "organismSearchText", "rowCount", "sampleIds", "selectedSamples", "sortDescriptors", "tableMode"]
        )
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 5)
        XCTAssertEqual(resolved["tableMode"]?.stringValue, "batchGroup")
        XCTAssertEqual(resolved["organismSearchText"]?.stringValue, "")
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-1", "sample-2"])
    }

    /// A column filter, a shown metadata column and a descending sort, written as CSV. The record names the sample
    /// metadata table and its edit journal because the leaf read them.
    func testTheLeafAppliesAFilterAndNamesTheMetadataFilesItRead() throws {
        let result = try makeResult()
        let output = root.appendingPathComponent("results.csv")
        let filter = ColumnFilter(columnId: "tt_reads", op: .greaterOrEqual, value: "10")
        _ = try run([
            result.path, "--output-format", "csv", "--metadata-column", "Group", "--sort", "tt_reads:descending",
            "--filter", ViewerTableExportState.encodedFilter(filter), "--output", output.path,
        ])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), [
            Self.header.replacingOccurrences(of: "\t", with: ",") + ",Group",
            "sample-1,Alpha virus,0.9100,42,21,50.00,High,1001,,,yes,case",
            "sample-1,Beta virus,0.7600,24,12,50.00,High,1002,,,,case",
            "sample-2,Gamma virus,0.5000,12,6,50.00,Medium,2001,,,yes,control",
        ].joined(separator: "\n") + "\n")

        let record = try envelope(of: output)
        XCTAssertEqual(
            inputNames(record),
            ["sample_metadata.tsv", "sample_metadata_edits.json", "taxtriage-result.json", "taxtriage.sqlite"]
        )
        XCTAssertEqual(
            record.options.explicit.keys.sorted(),
            ["filterMatch", "filters", "metadataColumns", "outputFormat", "outputPath", "sortKeys"]
        )
        XCTAssertEqual(record.options.resolvedDefaults["rowCount"]?.integerValue, 3)
        XCTAssertEqual(record.options.resolvedDefaults["metadataColumns"]?.arrayValue?.compactMap(\.stringValue), ["Group"])
    }

    /// A sort by a metadata column compares the samples' values, and the leaf then reads the metadata store whether or
    /// not the column is written.
    func testTheLeafSortsByAMetadataColumn() throws {
        let result = try makeResult()
        let output = root.appendingPathComponent("by-group.tsv")
        _ = try run([
            result.path, "--output-format", "tsv", "--sort", "metadata_Group:descending", "--output", output.path,
        ])
        let samples = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").dropFirst()
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
        XCTAssertEqual(samples.prefix(2), ["sample-2", "sample-2"], "control sorts before case, descending")
        XCTAssertEqual(Set(samples.suffix(3)), ["sample-1"])
        XCTAssertEqual(
            inputNames(try envelope(of: output)),
            ["sample_metadata.tsv", "sample_metadata_edits.json", "taxtriage-result.json", "taxtriage.sqlite"]
        )
    }

    /// A filter on a metadata column the export does not write still reads the metadata store, so the record names the
    /// table and its edit journal (F7-2, the rule 12.31 settled for NAO-MGS).
    func testTheLeafNamesTheMetadataFilesForAFilterOnAHiddenMetadataColumn() throws {
        let result = try makeResult()
        let output = root.appendingPathComponent("hidden-filter.tsv")
        let filter = ColumnFilter(columnId: "metadata_Group", op: .contains, value: "case")
        _ = try run([
            result.path, "--output-format", "tsv", "--filter", ViewerTableExportState.encodedFilter(filter),
            "--output", output.path,
        ])
        let samples = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").dropFirst()
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
        XCTAssertEqual(samples, ["sample-1", "sample-1", "sample-1"], "only the case sample passes the filter")
        XCTAssertEqual(
            inputNames(try envelope(of: output)),
            ["sample_metadata.tsv", "sample_metadata_edits.json", "taxtriage-result.json", "taxtriage.sqlite"]
        )
    }

    /// A sort by a metadata column needs the sample metadata table. With the table missing the leaf refuses before it
    /// writes a byte and names the file it could not read.
    func testTheLeafRefusesAMetadataSortWhenTheResultHoldsNoMetadataTable() throws {
        let result = try makeResult()
        try FileManager.default.removeItem(at: result.appendingPathComponent("metadata"))
        let output = root.appendingPathComponent("no-table.tsv")
        XCTAssertThrowsError(
            try run([
                result.path, "--output-format", "tsv", "--sort", "metadata_Group:ascending", "--output", output.path,
            ])
        ) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
            XCTAssertTrue("\(error)".contains("sample_metadata.tsv"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no output")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
            "no record"
        )
    }

    func testTheLeafRefusesWhatItCannotApplyBeforeItWritesAByte() throws {
        let result = try makeResult()
        let output = root.appendingPathComponent("refused.tsv")
        let base = [result.path, "--output-format", "tsv", "--output", output.path]
        let refusals: [(arguments: [String], mentions: String)] = [
            (["--sample", "sample-9"], "sample-9"),
            (["--metadata-column", "Nope"], "No metadata column Nope"),
            (["--sort", "tt_nope:ascending"], "tt_nope"),
        ]
        for refusal in refusals {
            XCTAssertThrowsError(try run(base + refusal.arguments), refusal.mentions) { error in
                XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
                XCTAssertTrue("\(error)".contains(refusal.mentions), "\(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), refusal.mentions)
        }
        try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try run(base)) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "keep", "an existing output is kept without --force")
    }

    /// The table orders by its first sort descriptor only, so a second `--sort` would be recorded and never applied.
    /// The leaf refuses it before it writes a byte, as the NAO-MGS leaf does.
    func testTheLeafRefusesASecondSortKey() throws {
        let result = try makeResult()
        let output = root.appendingPathComponent("two-sorts.tsv")
        XCTAssertThrowsError(
            try run([
                result.path, "--output-format", "tsv", "--sort", "tt_reads:descending", "--sort", "tt_organism:ascending",
                "--output", output.path,
            ])
        ) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
            XCTAssertTrue("\(error)".contains("one sort key"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no output")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
            "no record"
        )
    }
}
