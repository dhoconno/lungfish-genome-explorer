// TaxTriageExportCLIGUIParityReplayTests+Sides.swift - The fixture and the sides of the TaxTriage export parity cases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.32. The result folder the sidebar item opens, the view configured as the app's route configures
// it, side A (the in-app writers, frozen below since the lane deletes them from the view) and side C (the view's
// invocation and begin helper, which run the built CLI behind the row).

import AppKit
import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishTaxTriageUI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

extension TaxTriageExportCLIGUIParityReplayTests {
    static let resultFolderName = "taxtriage-result"
    static let sampleIds = ["sample-1", "sample-2"]

    /// The output each side writes, in its root.
    static func outputURL(_ export: Export, in root: URL) -> URL {
        let name: String
        switch export {
        case .matrix: name = "organism_matrix.csv"
        case .report: name = "batch_report.txt"
        case .resultsTSV: name = "results.tsv"
        case .resultsCSV: name = "results.csv"
        }
        return root.appendingPathComponent(name)
    }

    static func envelope(_ export: Export, in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(export, in: root)))
        )
    }

    // MARK: - The fixture

    /// The result folder the sidebar item opens. Five rows over two samples, `sample-2` marked as the negative
    /// control, the run's sidecar and the batch manifest no payload byte comes from (it is never an input).
    static func makeResult(_ root: URL) throws {
        let result = root.appendingPathComponent(resultFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        _ = try TaxTriageDatabase.create(
            at: result.appendingPathComponent(TaxTriageExportLoader.databaseFileName),
            rows: [
                row("sample-1", "Alpha virus", 1001, 0.91, 42, "High"),
                row("sample-1", "Beta virus", 1002, 0.76, 24, "High"),
                row("sample-1", "Delta, \"quoted\" virus", 3001, 0.60, 6, "Medium", storesUniqueReads: false),
                row("sample-2", "Gamma virus", 2001, 0.50, 12, "Medium"),
                row("sample-2", "Alpha virus", 1001, 0.20, 3, "Low"),
            ],
            metadata: ["tool": "taxtriage"]
        )
        let config = TaxTriageConfig(
            samples: sampleIds.map {
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
        try Data("{}".utf8).write(to: result.appendingPathComponent(TaxTriageBatchManifest.filename))
        // The sample metadata table and its edit journal. Only the results export reads them (F7-2), so neither the
        // matrix nor the report may name them.
        let metadata = result.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("Sample\tGroup\nsample-1\tcase\nsample-2\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        try Data("[]".utf8).write(to: metadata.appendingPathComponent("sample_metadata_edits.json"))
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

    // MARK: - The view

    /// A view configured as the app's route configures it (`ViewerViewController+TaxTriage.swift`), with the Sample
    /// Filter at `segment` (0 is All Samples) and the organism search typed. `searchRows` is the row count the search
    /// leaves. The view loads its rows on tasks of the main actor, so each wait yields it. An async test runs inside
    /// a main-actor job, where spinning the run loop would never run those tasks.
    static func configuredView(
        _ root: URL,
        defaults: UserDefaults,
        segment: Int = 0,
        search: String? = nil,
        searchRows: Int = 0,
        sortKey: String? = nil,
        sortAscending: Bool = true,
        filter: ColumnFilter? = nil,
        showsGroup: Bool = false
    ) async throws -> TaxTriageResultViewController {
        let resultURL = root.appendingPathComponent(resultFolderName, isDirectory: true)
        let database = try TaxTriageDatabase(at: resultURL.appendingPathComponent(TaxTriageExportLoader.databaseFileName))
        let view = TaxTriageResultViewController()
        // The view keeps the column layouts of its tables in the case's suite, so a throwaway result writes nothing to
        // the test host's own domain (`com.apple.dt.xctest.tool`), which outlives the run.
        view.layoutDefaults = defaults
        _ = view.view
        view.configureFromDatabase(database, resultURL: resultURL)
        await waitForRows(view) { $0.count == 5 }
        if segment > 0 {
            let control = view.testSampleFilterControl
            control.selectedSegment = segment
            _ = control.sendAction(control.action, to: control.target)
            let sample = sampleIds[segment - 1]
            await waitForRows(view) { $0.count == 3 && $0.allSatisfy { $0.sample == sample } }
        }
        if let search {
            let field = view.testingOrganismSearchField
            field.stringValue = search
            _ = field.sendAction(field.action, to: field.target)
            await waitForRows(view) { $0.count == searchRows }
        }
        if showsGroup {
            let store = try XCTUnwrap(SampleMetadataStore.load(from: resultURL, knownSampleIds: Set(sampleIds)))
            let columns = view.testBatchFlatTableView.metadataColumns
            columns.visibleColumns = ["Group"]
            columns.update(store: store, sampleId: nil)
        }
        if let sortKey {
            view.testBatchFlatTableView.columnHeaderFilterMenu(sortByKey: sortKey, ascending: sortAscending)
        }
        if let filter {
            view.testBatchFlatTableView.setColumnFilter(filter, for: filter.columnId)
        }
        await waitForContaminationKeys(view)
        return view
    }

    /// The defaults a case keeps the column layouts of its views in. `makeTestDefaultsSuite(prefix:)` empties and
    /// removes the suite when the test ends, so no layout of a throwaway result outlives the case.
    func layoutDefaults() -> UserDefaults {
        makeTestDefaultsSuite(prefix: "TaxTriageExportCLIGUIParityReplayTests").defaults
    }

    /// The view flags the organisms the negative control holds on a task of the main actor, so a wait yields it.
    static func waitForContaminationKeys(_ view: TaxTriageResultViewController) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while view.testBatchFlatTableView.contaminationRiskOrganismKeys.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.testBatchFlatTableView.contaminationRiskOrganismKeys.isEmpty, "negative-control flags did not load")
    }

    static func waitForRows(
        _ view: TaxTriageResultViewController,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: ([TaxTriageMetric]) -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(view.testBatchFlatTableView.displayedRows) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(view.testBatchFlatTableView.displayedRows), "rows did not load", file: file, line: line)
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: - Side A

    /// Side A. The in-app writer the view's Export ran before the leaf, frozen below.
    func sideA(_ root: URL, scenario: Scenario) async throws -> RouteParitySideOutcome {
        let view = try await Self.configuredView(
            root, defaults: layoutDefaults(), segment: scenario.segment, search: scenario.search, searchRows: scenario.searchRows,
            sortKey: scenario.sortKey, sortAscending: scenario.sortAscending, filter: scenario.filter,
            showsGroup: scenario.showsGroup
        )
        let output = Self.outputURL(scenario.export, in: root)
        do {
            switch scenario.export {
            case .matrix: try Self.frozenWriteBatchMatrixCSV(view: view, to: output)
            case .report: try Self.frozenWriteBatchReport(view: view, to: output)
            case .resultsTSV, .resultsCSV:
                try Self.frozenWriteDelimitedResults(
                    view: view, search: scenario.search ?? "", format: scenario.export == .resultsCSV ? "csv" : "tsv",
                    to: output
                )
            }
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(output.lastPathComponent)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `writeBatchMatrixCSV` as `TaxTriageResultViewController` held it at a737125426, reading the view through its
    /// test accessors. The views' private members are derived from state this file can read, and the class proves the
    /// derivation equal: the metrics are `metrics` or `allBatchGroupRows`, the negative controls come from the run's
    /// config, and the inputs are the result folder's database and, when the view loaded the run, its sidecar. Every
    /// production result opens in `batchGroup` mode (BIO ruling on 12.32, F1).
    static func frozenWriteBatchMatrixCSV(view: TaxTriageResultViewController, to url: URL) throws {
        let runClock = ProvenanceRunClock()
        let negativeControlIds = frozenNegativeControlSampleIds(view: view)
        let matrixMetrics = view.metrics.isEmpty ? view.allBatchGroupRows : view.metrics
        let sampleIds = view.sampleIds
        let csv = TaxTriageBatchExporter.generateOrganismMatrixCSV(
            metrics: matrixMetrics,
            sampleIds: sampleIds,
            negativeControlSampleIds: negativeControlIds
        )
        let exportedOrganismCount = frozenCrossSampleOrganismCount(in: matrixMetrics)
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app taxtriage organism matrix export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: frozenSourceURLs(view: view),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-taxtriage-organism-matrix", "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string("csv"),
            ],
            defaults: [
                "format": .string("csv"),
            ],
            resolved: [
                "rowCount": .integer(exportedOrganismCount),
                "exportedOrganismCount": .integer(exportedOrganismCount),
                "metricCount": .integer(matrixMetrics.count),
                "sampleCount": .integer(sampleIds.count),
                "sampleIds": .array(sampleIds.map { .string($0) }),
                "negativeControlSampleIds": .array(negativeControlIds.sorted().map { .string($0) }),
                "tableMode": .string("batchGroup"),
            ],
            runClock: runClock
        )) { outputURL in
            try csv.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    /// `writeBatchReport` as the view held it at a737125426, derived the same way.
    static func frozenWriteBatchReport(view: TaxTriageResultViewController, to url: URL) throws {
        let result = try XCTUnwrap(view.testResult)
        let config = try XCTUnwrap(view.taxTriageConfig)
        let runClock = ProvenanceRunClock()
        let negativeControlIds = frozenNegativeControlSampleIds(view: view)
        let reportMetrics = view.metrics.isEmpty ? view.allBatchGroupRows : view.metrics
        let sampleIds = view.sampleIds
        let report = TaxTriageBatchExporter.generateSummaryReport(
            result: result,
            config: config,
            metrics: reportMetrics,
            sampleIds: sampleIds
        )
        let reportLineCount = report.split(separator: "\n", omittingEmptySubsequences: false).count
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app taxtriage batch report export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: frozenSourceURLs(view: view),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-taxtriage-batch-report", "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string("txt"),
            ],
            defaults: [
                "format": .string("txt"),
            ],
            resolved: [
                "reportLineCount": .integer(reportLineCount),
                "metricCount": .integer(reportMetrics.count),
                "sampleCount": .integer(sampleIds.count),
                "exportedOrganismCount": .integer(frozenCrossSampleOrganismCount(in: reportMetrics)),
                "sampleIds": .array(sampleIds.map { .string($0) }),
                "negativeControlSampleIds": .array(negativeControlIds.sorted().map { .string($0) }),
                "classifierCount": .integer(config.classifiers.count),
                "tableMode": .string("batchGroup"),
            ],
            runClock: runClock
        )) { outputURL in
            try report.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    /// `writeDelimitedResults` with `buildDatabaseDelimitedExport` as the view held them at 5ab86f874 (the results
    /// writer at 23d403b2b with its builder passed the table's values), reading the view through its test accessors.
    /// The selected samples are the ticked ones in the view's sample order, and `search` is the text typed in the
    /// organism search field.
    static func frozenWriteDelimitedResults(
        view: TaxTriageResultViewController, search: String, format: String, to url: URL
    ) throws {
        let runClock = ProvenanceRunClock()
        let table = view.testBatchFlatTableView
        let metadataColumns = table.metadataColumns
        let rows = table.displayedRows
        var metadataValuesBySample: [String: [String]] = [:]
        for sample in Set(rows.map { $0.sample ?? "" }) {
            metadataValuesBySample[sample] = metadataColumns.exportValues(for: sample)
        }
        let content = TaxTriageResultsExport.buildDelimitedExport(
            rows: rows,
            totalReadsByKey: table.totalReadsByKey,
            uniqueReadsByKey: table.uniqueReadsByKey,
            contaminationRiskOrganismKeys: table.contaminationRiskOrganismKeys,
            metadataHeaders: metadataColumns.exportHeaders,
            metadataValuesBySample: metadataValuesBySample,
            separator: format == "csv" ? "," : "\t"
        )
        let ticked = Set(view.selectedDatabaseSampleIds)
        let sortDescriptors: [ParameterValue] = table.tableView.sortDescriptors.map { descriptor in
            .dictionary([
                "key": descriptor.key.map(ParameterValue.string) ?? .null,
                "ascending": .boolean(descriptor.ascending),
                "selector": descriptor.selector.map { .string(NSStringFromSelector($0)) } ?? .null,
            ])
        }
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app taxtriage results export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: frozenSourceURLs(view: view, writesMetadata: !metadataColumns.exportHeaders.isEmpty),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-taxtriage-results", "--format", format, "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string(format),
            ],
            defaults: [
                "format": .string("tsv"),
            ],
            resolved: [
                "rowCount": .integer(rows.count),
                "sampleIds": .array(view.sampleIds.map { .string($0) }),
                "selectedSamples": .array(view.sampleIds.filter { ticked.contains($0) }.map { .string($0) }),
                "organismSearchText": .string(search),
                "tableMode": .string("batchGroup"),
                "sortDescriptors": .array(sortDescriptors),
                "metadataColumns": .array(metadataColumns.exportHeaders.map { .string($0) }),
            ],
            runClock: runClock
        )) { outputURL in
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    private static func frozenNegativeControlSampleIds(view: TaxTriageResultViewController) -> Set<String> {
        guard let config = view.taxTriageConfig else { return [] }
        return Set(config.samples.filter(\.isNegativeControl).map(\.sampleId))
    }

    private static func frozenCrossSampleOrganismCount(in metrics: [TaxTriageMetric]) -> Int {
        Set(metrics.map { $0.organism.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }).count
    }

    private static func frozenSourceURLs(view: TaxTriageResultViewController, writesMetadata: Bool = false) -> [URL] {
        guard let resultURL = view.batchGroupURL else { return [] }
        var urls = [resultURL.appendingPathComponent(TaxTriageExportLoader.databaseFileName)]
        if view.testResult != nil {
            urls.append(resultURL.appendingPathComponent(TaxTriageExportLoader.sidecarFileName))
        }
        urls += EsVirituDetectionExport.metadataInputURLs(in: resultURL, writesMetadata: writesMetadata)
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Side C

    /// The row of `export` for the view's state, which runs the built CLI on the shared runner.
    static func begin(
        _ export: Export,
        view: TaxTriageResultViewController,
        output: URL,
        runner: CLIViewerExportRunner,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        switch export {
        case .matrix:
            guard let invocation = view.organismMatrixExportInvocation(outputURL: output) else { return nil }
            return TaxTriageResultViewController.beginTaxTriageOrganismMatrixExportOperation(
                invocation: invocation, runner: runner, environmentAdditions: environmentAdditions, onFailure: onFailure
            )
        case .report:
            guard let invocation = view.batchReportExportInvocation(outputURL: output) else { return nil }
            return TaxTriageResultViewController.beginTaxTriageBatchReportExportOperation(
                invocation: invocation, runner: runner, environmentAdditions: environmentAdditions, onFailure: onFailure
            )
        case .resultsTSV, .resultsCSV:
            guard let invocation = view.resultsExportInvocation(
                format: export == .resultsCSV ? .csv : .tsv, outputURL: output
            ) else { return nil }
            return TaxTriageResultViewController.beginTaxTriageResultsExportOperation(
                invocation: invocation, runner: runner, environmentAdditions: environmentAdditions, onFailure: onFailure
            )
        }
    }

    /// Side C. The view's invocation and begin helper, which run the built CLI behind the row.
    func sideC(_ root: URL, scenario: Scenario) async throws -> RouteParitySideOutcome {
        let view = try await Self.configuredView(
            root, defaults: layoutDefaults(), segment: scenario.segment, search: scenario.search, searchRows: scenario.searchRows,
            sortKey: scenario.sortKey, sortAscending: scenario.sortAscending, filter: scenario.filter,
            showsGroup: scenario.showsGroup
        )
        let failures = TaxTriageExportFailureCalls()
        guard let begun = Self.begin(
            scenario.export,
            view: view,
            output: Self.outputURL(scenario.export, in: root),
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { failure in failures.messages.append(failure.message) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(failures.messages, [])
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }

    // MARK: - The cancel

    /// ARCH ruling 1.6 and X14 for one export. The row's Cancel stops the leaf inside its transaction, the row reads
    /// Cancelled with no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125
    /// inside the grace. Neither leaves the output or its record. The case root sits five levels below the temporary
    /// folder, so the record's five-folder input walk stays inside the case (SCR/lanes/12.31/12.31-cancel.md).
    func assertCancelled(_ export: Export) async throws {
        let root = scratch.appendingPathComponent("cancel-\(export.rawValue)/case/run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeResult(root)
        let output = Self.outputURL(export, in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let view = try await Self.configuredView(root, defaults: layoutDefaults())

        let failures = TaxTriageExportFailureCalls()
        let begun = try XCTUnwrap(Self.begin(
            export,
            view: view,
            output: output,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path],
            onFailure: { failure in failures.messages.append(failure.message) }
        ))
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "\(export): the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled, "\(export)")
        XCTAssertEqual(item?.state, .cancelled, "\(export)")
        XCTAssertEqual(failures.messages, [], "\(export): a cancel shows no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(export): a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "\(export): a cancel leaves no record")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "\(export): the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled, "\(export)")
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(export): a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "\(export): a cancel leaves no record")
    }
}
