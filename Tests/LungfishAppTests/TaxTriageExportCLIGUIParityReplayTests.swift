// TaxTriageExportCLIGUIParityReplayTests.swift - The TaxTriage organism matrix and batch report exports in the app against their CLI leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.32, ARCH ruling on the export shape 1.7, BIO ruling on 12.32 (F1, F2, F6, F7), on lane Q30's
// harness. Each case runs on three sides that start as copies of one TaxTriage result folder, a database of two
// samples with a negative control, the run's sidecar and the batch manifest no export reads.
//
// - Side A is the in-app writer, `writeBatchMatrixCSV` or `writeBatchReport` as the view held it at a737125426,
//   frozen in TaxTriageExportCLIGUIParityReplayTests+Sides.swift since the lane deletes it from the view, run on a
//   view configured from the database as the app's route configures it.
// - Side C is the view's begin helper, `beginTaxTriageOrganismMatrixExportOperation` or
//   `beginTaxTriageBatchReportExportOperation`, with the invocation the view builds. It begins the row and runs the
//   built `lungfish-cli taxtriage export` leaf on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares what 1.7 names, which is the payload byte for byte, the record's inputs with their digests, the
// output's digest and size, and every `resolved` key, with no file but the record differing. The report's `Date:`
// line holds the clock of the run that writes it (F6), so the report compares with that line masked and its digest is
// not compared. The five identity fields of the record are prediction rows of the lane report (BIO 7), pinned on each
// side by `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks. Nothing is
// declared, so the old writers go in the lane with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier. Every
// case root sits five levels below the temporary folder, so the record's five-folder input walk stays inside the case.

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishTaxTriageUI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxTriageExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class TaxTriageExportCLIGUIParityReplayTests: XCTestCase {
    enum Export: String, Sendable {
        case matrix
        case report
        case resultsTSV
        case resultsCSV
    }

    /// What a case sets in the view before it exports. `segment` is the Sample Filter, where 0 is All Samples, and
    /// `searchRows` the row count the typed search leaves.
    struct Scenario: Sendable {
        let export: Export
        let segment: Int
        let search: String?
        let searchRows: Int
        var sortKey: String? = nil
        var sortAscending = true
        var filter: ColumnFilter? = nil
        var showsGroup = false
    }

    enum Case: String, Sendable {
        case matrixOfTwoSamplesWithControl
        case matrixOfOneSampleWithSearch
        case reportOfTwoSamplesWithControl
        case reportOfOneSampleWithSearch
        case resultsTSVOfTwoSamplesSortedByReads
        case resultsCSVOfOneSampleWithSearchSortAndFilter
        case resultsTSVWithAMetadataColumnSortedByIt
        case resultsTSVSortedByConfidenceDescending

        var scenario: Scenario {
            switch self {
            case .matrixOfTwoSamplesWithControl: Scenario(export: .matrix, segment: 0, search: nil, searchRows: 0)
            case .matrixOfOneSampleWithSearch: Scenario(export: .matrix, segment: 1, search: "beta", searchRows: 1)
            case .reportOfTwoSamplesWithControl: Scenario(export: .report, segment: 0, search: nil, searchRows: 0)
            case .reportOfOneSampleWithSearch: Scenario(export: .report, segment: 1, search: "alpha", searchRows: 1)
            case .resultsTSVOfTwoSamplesSortedByReads:
                Scenario(
                    export: .resultsTSV, segment: 0, search: nil, searchRows: 0, sortKey: "tt_reads",
                    filter: ColumnFilter(columnId: "tt_reads", op: .greaterOrEqual, value: "5")
                )
            case .resultsCSVOfOneSampleWithSearchSortAndFilter:
                Scenario(
                    export: .resultsCSV, segment: 1, search: "e", searchRows: 2, sortKey: "tt_tassScore",
                    filter: ColumnFilter(columnId: "tt_confidence", op: .contains, value: "medium")
                )
            case .resultsTSVWithAMetadataColumnSortedByIt:
                Scenario(
                    export: .resultsTSV, segment: 0, search: nil, searchRows: 0, sortKey: "metadata_Group",
                    sortAscending: false, showsGroup: true
                )
            case .resultsTSVSortedByConfidenceDescending:
                Scenario(
                    export: .resultsTSV, segment: 0, search: nil, searchRows: 0, sortKey: "tt_confidence",
                    sortAscending: false
                )
            }
        }
    }

    /// The `resolved` keys both sides write, compared value for value.
    static let matrixKeys: Set<String> = [
        "exportedOrganismCount", "metricCount", "negativeControlSampleIds", "rowCount", "sampleCount", "sampleIds",
        "tableMode",
    ]
    static let reportKeys: Set<String> = [
        "classifierCount", "exportedOrganismCount", "metricCount", "negativeControlSampleIds", "reportLineCount",
        "sampleCount", "sampleIds", "tableMode",
    ]
    static let resultsKeys: Set<String> = [
        "metadataColumns", "organismSearchText", "rowCount", "sampleIds", "selectedSamples", "sortDescriptors",
        "tableMode",
    ]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"

    var scratch: URL!
    var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "taxtriage-export-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// Both samples ticked, `sample-2` the negative control. The matrix flags the organisms the control holds.
    func testMatrixOfTwoSamplesWithControlMatches() async throws {
        let runs = try await assertParity(.matrixOfTwoSamplesWithControl)
        let lines = try String(contentsOf: Self.outputURL(.matrix, in: runs.c.root), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5, "\(lines)")
        XCTAssertEqual(lines.first, "Organism,Mean TASS,Samples Detected,Contamination Risk,sample-1,sample-2")
        XCTAssertTrue(lines.contains("Alpha virus,0.5550,2/2,Yes,0.9100,0.2000"), "\(lines)")
        let resolved = try Self.envelope(.matrix, in: runs.c.root).options.resolvedDefaults
        XCTAssertEqual(resolved["metricCount"]?.integerValue, 5)
        XCTAssertEqual(resolved["exportedOrganismCount"]?.integerValue, 4)
        XCTAssertEqual(resolved["negativeControlSampleIds"]?.arrayValue?.compactMap(\.stringValue), ["sample-2"])
    }

    /// One of the two samples ticked and the search "beta", so the command names one `--sample` and one `--search`.
    func testMatrixOfOneSampleWithSearchMatches() async throws {
        let runs = try await assertParity(.matrixOfOneSampleWithSearch)
        let lines = try String(contentsOf: Self.outputURL(.matrix, in: runs.c.root), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "Organism,Mean TASS,Samples Detected,Contamination Risk,sample-1,sample-2",
            "Beta virus,0.7600,1/2,No,0.7600,",
        ])
        let record = try Self.envelope(.matrix, in: runs.c.root)
        XCTAssertEqual(record.argv.filter { $0 == "--sample" }.count, 1)
        XCTAssertEqual(record.argv.filter { $0 == "--search" }.count, 1)
        XCTAssertEqual(record.options.resolvedDefaults["metricCount"]?.integerValue, 1)
        XCTAssertEqual(record.options.resolvedDefaults["sampleCount"]?.integerValue, 2, "the report names every sample")
    }

    /// F6. The report's `Date:` line holds the clock of the run that writes it.
    func testReportOfTwoSamplesWithControlMatches() async throws {
        let runs = try await assertParity(.reportOfTwoSamplesWithControl)
        let text = try String(contentsOf: Self.outputURL(.report, in: runs.c.root), encoding: .utf8)
        XCTAssertTrue(text.contains("Samples: 2"), text)
        XCTAssertTrue(text.contains("Negative Controls: sample-2"), text)
        XCTAssertTrue(text.contains("Alpha virus: 2/2 samples, mean TASS=0.555 [CONTAMINATION RISK]"), text)
        let resolved = try Self.envelope(.report, in: runs.c.root).options.resolvedDefaults
        XCTAssertEqual(resolved["metricCount"]?.integerValue, 5)
        XCTAssertEqual(resolved["exportedOrganismCount"]?.integerValue, 4)
    }

    func testReportOfOneSampleWithSearchMatches() async throws {
        let runs = try await assertParity(.reportOfOneSampleWithSearch)
        let text = try String(contentsOf: Self.outputURL(.report, in: runs.c.root), encoding: .utf8)
        XCTAssertTrue(text.contains("Alpha virus: mean TASS=0.910, 1 sample(s)"), text)
        let record = try Self.envelope(.report, in: runs.c.root)
        XCTAssertEqual(record.argv.filter { $0 == "--sample" }.count, 1)
        XCTAssertEqual(record.options.resolvedDefaults["metricCount"]?.integerValue, 1)
    }

    /// BIO ruling on 12.32 F3 and F5. Two samples, the reads column sorted ascending and a reads filter that drops
    /// the row of 3 reads. The Delta row stores no Unique Reads, so its cell is empty on both sides, and the
    /// organisms the negative control holds are flagged in every sample.
    func testResultsTSVOfTwoSamplesSortedByReadsMatches() async throws {
        let runs = try await assertParity(.resultsTSVOfTwoSamplesSortedByReads)
        let lines = try Self.payload(.resultsTSV, in: runs.c.root).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5, "\(lines)")
        XCTAssertTrue(lines[1].hasPrefix("sample-1\tDelta, \"quoted\" virus\t0.6000\t6\t\t"), "\(lines)")
        XCTAssertTrue(lines[4].hasPrefix("sample-1\tAlpha virus\t0.9100\t42\t21\t"), "\(lines)")
        XCTAssertTrue(lines[4].hasSuffix("\tyes"), "the organism the control holds is flagged: \(lines)")
    }

    /// One sample, the search "e", the TASS column sorted and a Confidence filter, written as CSV.
    func testResultsCSVOfOneSampleWithSearchSortAndFilterMatches() async throws {
        let runs = try await assertParity(.resultsCSVOfOneSampleWithSearchSortAndFilter)
        let lines = try Self.payload(.resultsCSV, in: runs.c.root).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertEqual(lines[1], "sample-1,\"Delta, \"\"quoted\"\" virus\",0.6000,6,,50.00,Medium,3001,,,")
        let record = try Self.envelope(.resultsCSV, in: runs.c.root)
        for flag in ["--sample", "--search", "--sort", "--filter"] {
            XCTAssertEqual(record.argv.filter { $0 == flag }.count, 1, flag)
        }
    }

    /// F7-2. A shown metadata column is written and sorted by, so the record names the metadata files.
    func testResultsTSVWithAMetadataColumnSortedByItMatches() async throws {
        let runs = try await assertParity(.resultsTSVWithAMetadataColumnSortedByIt)
        let lines = try Self.payload(.resultsTSV, in: runs.c.root).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix("\tGroup"), "\(lines)")
        XCTAssertTrue(lines[1].hasSuffix("\tcontrol") && lines[2].hasSuffix("\tcontrol"), "\(lines)")
        XCTAssertTrue(lines[3].hasSuffix("\tcase"), "\(lines)")
    }

    /// BIO review of 12.32 A6, Fix 3. No other case sorts a column with ties. Confidence descending ties twice (two
    /// Medium rows and two High rows), and a descending comparator is `ascending ? result : !result`, which is not a
    /// strict weak order, so the order of tied rows rests on both sides sorting the same input. A equals C byte for
    /// byte, and the copy of the comparator in the leaf is then the table's.
    func testResultsTSVSortedByConfidenceDescendingMatches() async throws {
        let runs = try await assertParity(.resultsTSVSortedByConfidenceDescending)
        let lines = try Self.payload(.resultsTSV, in: runs.c.root).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 6, "\(lines)")
        XCTAssertTrue(lines[1].contains("\tMedium\t") && lines[2].contains("\tMedium\t"), "\(lines)")
        XCTAssertTrue(lines[3].contains("\tLow\t"), "\(lines)")
        XCTAssertTrue(lines[4].contains("\tHigh\t") && lines[5].contains("\tHigh\t"), "\(lines)")
    }

    /// BIO review of 12.32 A6, Fix 1. The table orders by its first sort descriptor only, and AppKit keeps the earlier
    /// header sorts behind it, so the view passes the first descriptor and the record never names a sort that was
    /// not applied.
    func testTheViewPassesOnlyItsFirstSortDescriptor() async throws {
        let root = scratch.appendingPathComponent("first-sort-descriptor", isDirectory: true)
        try Self.makeResult(root)
        let view = try await Self.configuredView(root, defaults: layoutDefaults())
        view.testBatchFlatTableView.tableView.sortDescriptors = [
            NSSortDescriptor(key: "tt_reads", ascending: false),
            NSSortDescriptor(key: "tt_organism", ascending: true),
        ]
        let invocation = try XCTUnwrap(
            view.resultsExportInvocation(format: .tsv, outputURL: root.appendingPathComponent("two-descriptors.tsv"))
        )
        XCTAssertEqual(invocation.state.sortKeys, [ViewerExportSortKey(column: "tt_reads", ascending: false)])
    }

    /// ARCH ruling 1.6 and X14, for the three leaves.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        try await assertCancelled(.matrix)
        try await assertCancelled(.report)
        try await assertCancelled(.resultsTSV)
    }
}

// MARK: - The comparison

extension TaxTriageExportCLIGUIParityReplayTests {
    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on the compared facts, and the
    /// predicted record changes hold.
    @discardableResult
    func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let scenario = parityCase.scenario
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("cases/\(parityCase.rawValue)", isDirectory: true),
            fixture: Self.makeResult,
            sideA: { root in try await self.sideA(root, scenario: scenario) },
            sideC: { root in try await self.sideC(root, scenario: scenario) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "side \(side) names no other side's root")
        }
        // The report's Date line is the clock of each run, so a difference in the report file itself is read through
        // the masked text below and every other difference stands.
        let reportName = Self.outputURL(.report, in: runs.c.root).lastPathComponent
        let cAgainstCPrime = (found[.cAgainstCPrime] ?? []).filter {
            scenario.export != .report || !$0.id.contains(reportName)
        }
        XCTAssertEqual(cAgainstCPrime.map(\.description), [], "C against C' declares nothing")
        if scenario.export == .report {
            XCTAssertEqual(
                Self.masked(try Self.payload(.report, in: runs.c.root)),
                Self.masked(try Self.payload(.report, in: runs.cPrime.root)),
                "C against C', the Date line masked"
            )
        }
        try assertAEqualsC(runs, scenario: scenario)
        try assertPredictedRecordChanges(runs, scenario: scenario)
        return runs
    }

    /// A against C on the facts of 1.7, with each record path read relative to its side root. No file but the
    /// record differs, and the record's compared facts are equal.
    private func assertAEqualsC(_ runs: RouteParityRuns, scenario: Scenario) throws {
        let export = scenario.export
        let output = Self.outputURL(export, in: runs.a.root)
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: output).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(sidecarName) && (export != .report || !$0.id.contains(output.lastPathComponent))
        }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payloadA = try Data(contentsOf: Self.outputURL(export, in: runs.a.root))
        let payloadC = try Data(contentsOf: Self.outputURL(export, in: runs.c.root))
        let a = try Self.envelope(export, in: runs.a.root)
        let c = try Self.envelope(export, in: runs.c.root)
        let outputA = try XCTUnwrap(a.output)
        let outputC = try XCTUnwrap(c.output)
        switch export {
        case .matrix, .resultsTSV, .resultsCSV:
            XCTAssertEqual(payloadA, payloadC, "the payload byte for byte")
            XCTAssertNotNil(outputA.checksumSHA256)
            XCTAssertEqual(outputA.checksumSHA256, outputC.checksumSHA256, "the output digest")
            XCTAssertEqual(outputC.checksumSHA256, try ProvenanceFileHasher.sha256(of: Self.outputURL(export, in: runs.c.root)), "the recorded output digest equals the file")
        case .report:
            let textA = try Self.payload(.report, in: runs.a.root)
            let textC = try Self.payload(.report, in: runs.c.root)
            XCTAssertEqual(Self.masked(textA), Self.masked(textC), "the payload, the Date line masked")
            XCTAssertTrue(Self.hasISODate(textA), "side A's Date line holds the run's clock")
            XCTAssertTrue(Self.hasISODate(textC), "side C's Date line holds the run's clock")
            XCTAssertEqual(outputA.checksumSHA256, try ProvenanceFileHasher.sha256(of: Self.outputURL(.report, in: runs.a.root)))
            XCTAssertEqual(outputC.checksumSHA256, try ProvenanceFileHasher.sha256(of: Self.outputURL(.report, in: runs.c.root)))
        }
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root), Self.inputs(of: c, under: runs.c.root), "inputs and digests")
        for (path, digest) in Self.inputs(of: c, under: runs.c.root) { XCTAssertEqual(digest, try ProvenanceFileHasher.sha256(of: runs.c.root.appendingPathComponent(String(path.dropFirst()))), "recorded digest of \(path)") }
        var expectedInputs = ["/taxtriage-result/taxtriage-result.json", "/taxtriage-result/taxtriage.sqlite"]
        if scenario.showsGroup {
            expectedInputs += [
                "/taxtriage-result/metadata/sample_metadata.tsv", "/taxtriage-result/metadata/sample_metadata_edits.json",
            ]
        }
        XCTAssertEqual(
            Self.inputs(of: c, under: runs.c.root).keys.sorted(),
            expectedInputs.sorted(),
            "the database and the run's sidecar, and the metadata files only when a metadata column is read, never the batch manifest (BIO 6, F7-2)"
        )
        XCTAssertEqual(outputA.fileSize, UInt64(payloadA.count))
        XCTAssertEqual(outputC.fileSize, UInt64(payloadC.count))
        XCTAssertEqual(outputA.fileSize, outputC.fileSize, "the output size")
        let shared: Set<String>
        switch export {
        case .matrix: shared = Self.matrixKeys
        case .report: shared = Self.reportKeys
        case .resultsTSV, .resultsCSV: shared = Self.resultsKeys
        }
        let resolvedA = a.options.resolvedDefaults
        let resolvedC = c.options.resolvedDefaults
        XCTAssertEqual(Set(resolvedA.keys), shared)
        XCTAssertEqual(Set(resolvedC.keys), shared)
        for key in shared.sorted() {
            XCTAssertEqual(resolvedA[key], resolvedC[key], "resolved \(key)")
        }
    }

    /// The prediction rows of the lane report (BIO 7). The five identity fields move from the app's writer to the
    /// leaf. The record's argv is the row's command (ARCH 2). The view state the leaf takes is `explicit`.
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, scenario: Scenario) throws {
        let export = scenario.export
        let a = try Self.envelope(export, in: runs.a.root)
        let c = try Self.envelope(export, in: runs.c.root)
        let outputA = Self.outputURL(export, in: runs.a.root)
        let ext = export == .resultsCSV ? "csv" : "tsv"
        let argvA: [String]
        let format: String
        let defaultFormat: String
        let workflowA: String
        let workflowC: String
        switch export {
        case .matrix:
            argvA = ["Lungfish.app", "export-taxtriage-organism-matrix", "--output", outputA.path]
            format = "csv"
            defaultFormat = "csv"
            workflowA = "lungfish app taxtriage organism matrix export"
            workflowC = TaxTriageOrganismMatrixExport.workflowName
        case .report:
            argvA = ["Lungfish.app", "export-taxtriage-batch-report", "--output", outputA.path]
            format = "txt"
            defaultFormat = "txt"
            workflowA = "lungfish app taxtriage batch report export"
            workflowC = TaxTriageBatchReportExport.workflowName
        case .resultsTSV, .resultsCSV:
            argvA = ["Lungfish.app", "export-taxtriage-results", "--format", ext, "--output", outputA.path]
            format = ext
            defaultFormat = "tsv"
            workflowA = "lungfish app taxtriage results export"
            workflowC = TaxTriageResultsExport.workflowName
        }
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, workflowA)
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["format", "outputPath"])
        XCTAssertEqual(a.options.explicit["format"]?.stringValue, format)
        XCTAssertEqual(a.options.defaults["format"]?.stringValue, defaultFormat)

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, workflowC)
        let expectedSamples = scenario.segment == 0 ? Self.sampleIds : [Self.sampleIds[scenario.segment - 1]]
        var expectedKeys = ["outputPath", "samples"]
        if scenario.search != nil { expectedKeys.append("searchText") }
        if export == .resultsTSV || export == .resultsCSV {
            expectedKeys.append("outputFormat")
            if scenario.sortKey != nil { expectedKeys.append("sortKeys") }
            if scenario.filter != nil { expectedKeys += ["filters", "filterMatch"] }
            if scenario.showsGroup { expectedKeys.append("metadataColumns") }
        }
        XCTAssertEqual(c.options.explicit.keys.sorted(), expectedKeys.sorted())
        XCTAssertEqual(c.options.explicit["samples"]?.arrayValue?.compactMap(\.stringValue), expectedSamples)
        XCTAssertEqual(c.options.explicit["searchText"]?.stringValue, scenario.search)
        XCTAssertTrue(c.options.defaults.isEmpty)
    }

    // MARK: - Helpers

    static func payload(_ export: Export, in root: URL) throws -> String {
        try String(contentsOf: outputURL(export, in: root), encoding: .utf8)
    }

    /// The report with the clock of its run masked.
    static func masked(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("Date: ") ? "Date: <masked>" : String($0) }
            .joined(separator: "\n")
    }

    /// Whether the report's `Date:` line holds an ISO 8601 time.
    static func hasISODate(_ text: String) -> Bool {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Date: ") }) else { return false }
        return ISO8601DateFormatter().date(from: String(line.dropFirst("Date: ".count))) != nil
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}
