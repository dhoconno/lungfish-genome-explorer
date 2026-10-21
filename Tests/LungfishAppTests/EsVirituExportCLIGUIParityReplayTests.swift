// EsVirituExportCLIGUIParityReplayTests.swift - The EsViritu detections export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M3, ARCH ruling on the export shape 1.7, BIO rulings on 12.31 G1 and G3, on lane Q30's
// harness. Each case runs on three sides that start as copies of one EsViritu result folder, a database of two
// samples, a sample metadata table that gives them different groups, and the batch manifest the view caches.
//
// - Side A is the in-app writer, `writeDelimitedDetections` as the view held it at 25c696e5a with the G1 and G3 fixes
//   (G3-3), frozen in this file since the lane deletes it from the view, run on a view configured from the database
//   as the app's route configures it.
// - Side C is the view's begin helper, `beginEsVirituDetectionsExportOperation`, with the invocation the view builds.
//   It begins the row and runs the built `lungfish-cli esviritu export detections` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares what 1.7 names, which is the payload byte for byte, the record's inputs with their digests,
// the output's digest and size, and every `resolved` key both sides write, with no file but the record differing.
// The five identity fields and the keys side A recorded but never applied are prediction rows of the lane report
// (BIO 7), pinned on each side by `assertPredictedRecordChanges`. C against C' compares everything under the
// contract's masks. Nothing is declared, so the old writer goes in the lane with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class EsVirituExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class EsVirituExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case batchOfTwoSamplesWithMetadata
        case oneSelectedSample
    }

    /// The `resolved` keys both sides write, compared value for value.
    static let sharedResolvedKeys: Set<String> = [
        "metadataColumns", "rowCount", "sampleId", "selectedSamples", "sourceSampleCount", "tableMode",
    ]
    /// The keys side A recorded for view state its builder never applied (ARCH ruling 1.2, BIO 4).
    static let unappliedKeys: Set<String> = ["columnFilterComposition", "columnFilters", "searchText", "sortDescriptors"]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "esviritu-export-parity")
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

    /// BIO ruling on 12.31 G1, G1-4. Both samples selected and `Group` shown. Each row carries its own sample's value.
    func testBatchOfTwoSamplesWithMetadataMatches() async throws {
        let runs = try await assertParity(.batchOfTwoSamplesWithMetadata, samples: ["sample-A", "sample-B"])
        let lines = try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.count == 3 && lines[1].hasPrefix("sample-A\t") && lines[1].hasSuffix("\tcase"), "\(lines)")
        XCTAssertTrue(lines.count == 3 && lines[2].hasPrefix("sample-B\t") && lines[2].hasSuffix("\tcontrol"), "\(lines)")
        let resolved = try Self.envelope(in: runs.c.root).options.resolvedDefaults
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-A", "sample-B"])
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 2)
    }

    /// BIO ruling on 12.31 G1, G1-4. One of the two samples selected, so the command names one `--sample`.
    func testOneSelectedSampleMatches() async throws {
        let runs = try await assertParity(.oneSelectedSample, samples: ["sample-B"])
        let record = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(record.argv.filter { $0 == "--sample" }.count, 1)
        XCTAssertEqual(record.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-B"])
        XCTAssertEqual(record.options.resolvedDefaults["rowCount"]?.integerValue, 1)
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeResult(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let view = try Self.configuredView(root, samples: ["sample-A", "sample-B"])
        let invocation = try XCTUnwrap(
            view.detectionsExportInvocation(result: try XCTUnwrap(view.esVirituResult), format: .tsv, outputURL: output)
        )

        let failures = EsVirituExportFailureCalls()
        let begun = try XCTUnwrap(EsVirituResultViewController.beginEsVirituDetectionsExportOperation(
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { failure in failures.messages.append(failure.message) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(failures.messages, [], "a cancel shows no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }
}

// MARK: - The sides and the comparison

extension EsVirituExportCLIGUIParityReplayTests {
    static let resultFolderName = "esviritu-batch"

    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent("detections.tsv")
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The result folder the sidebar item opens, with its database of two samples, the sample metadata table and
    /// the batch manifest no payload byte comes from (BIO ruling on 12.31 G3).
    static func makeResult(_ root: URL) throws {
        let result = root.appendingPathComponent(resultFolderName, isDirectory: true)
        let metadata = result.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try EsVirituDatabase.create(
            at: result.appendingPathComponent(EsVirituDetectionExport.databaseFileName),
            rows: [row(sample: "sample-A", accession: "NC_A", reads: 40), row(sample: "sample-B", accession: "NC_B", reads: 20)],
            metadata: ["tool": "test"]
        )
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        try Data("{}".utf8).write(to: result.appendingPathComponent(EsVirituBatchAggregatedManifest.filename))
    }

    private static func row(sample: String, accession: String, reads: Int) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample, virusName: "Virus \(accession)", description: nil, contigLength: 100, segment: nil,
            accession: accession, assembly: "GCF_\(accession)", assemblyLength: 100, kingdom: "Viruses",
            phylum: nil, tclass: nil, torder: nil, family: "Testviridae", genus: nil, species: nil, subspecies: nil,
            rpkmf: 1, readCount: reads, uniqueReads: reads, coveredBases: 90, meanCoverage: 2,
            avgReadIdentity: 99, pi: 0, filteredReadsInSample: 1_000, bamPath: nil, bamIndexPath: nil
        )
    }

    /// A view configured as the app's route configures it (`ViewerViewController+EsViritu.swift`), with the sample
    /// metadata the app loads, `Group` shown and `samples` picked.
    static func configuredView(_ root: URL, samples: Set<String>) throws -> EsVirituResultViewController {
        let resultURL = root.appendingPathComponent(resultFolderName, isDirectory: true)
        let database = try EsVirituDatabase(at: resultURL.appendingPathComponent(EsVirituDetectionExport.databaseFileName))
        let view = EsVirituResultViewController()
        let layouts = TestDefaultsSuite(prefix: "EsVirituExportCLIGUIParityReplayTests")
        view.testDetectionTableView.metadataColumns.userDefaults = layouts.defaults
        view.testBatchTableView.metadataColumns.userDefaults = layouts.defaults
        _ = view.view
        view.configureFromDatabase(database, resultURL: resultURL)
        let sampleIds = try database.fetchSamples().map(\.sample)
        view.applySampleMetadata(SampleMetadataStore.load(from: resultURL, knownSampleIds: Set(sampleIds)))
        view.testDetectionTableView.metadataColumns.visibleColumns = ["Group"]
        view.samplePickerState.selectedSamples = samples
        view.applyBatchSampleFilter()
        XCTAssertEqual(view.testDetectionTableView.metadataColumns.exportHeaders, ["Group"])
        return view
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Side A. The in-app writer the view's Export ran before the leaf, frozen below.
    private func sideA(_ root: URL, samples: Set<String>) throws -> RouteParitySideOutcome {
        let view = try Self.configuredView(root, samples: samples)
        let result = try XCTUnwrap(view.esVirituResult)
        do {
            try Self.frozenWriteDelimitedDetections(
                view: view, result: result, separator: "\t", fileExtension: "tsv", to: Self.outputURL(in: root)
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported detections.tsv")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `writeDelimitedDetections` and its helpers as `EsVirituResultViewController` held them at 25c696e5a, reading
    /// the view through its test accessors. The database is the result folder's, which `configuredView` opens.
    private static func frozenWriteDelimitedDetections(
        view: EsVirituResultViewController,
        result: LungfishIO.EsVirituResult,
        separator: String,
        fileExtension: String,
        to url: URL
    ) throws {
        let runClock = ProvenanceRunClock()
        let table = view.testDetectionTableView
        let metadata = table.metadataColumns
        let sampleIds = Set(result.detections.map(\.sampleId))
        let content = EsVirituDetectionExport.buildDelimitedExport(
            result: result,
            separator: separator,
            metadataHeaders: metadata.exportHeaders,
            metadataValuesBySample: Dictionary(uniqueKeysWithValues: sampleIds.map { ($0, metadata.exportValues(for: $0)) })
        )
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app esviritu detections export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: frozenSourceURLs(view: view),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-esviritu-detections", "--format", fileExtension, "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string(fileExtension),
            ],
            defaults: [
                "format": .string("tsv"),
            ],
            resolved: [
                "rowCount": .integer(result.detections.count),
                "sampleId": .string(result.sampleId),
                "selectedSamples": .array(frozenSelectedSampleIds(view: view, result: result).map(ParameterValue.string)),
                "sourceSampleCount": .integer(view.sampleEntries.count),
                "tableMode": .string(view.isBatchMode ? "batchHierarchical" : "singleSample"),
                "searchText": .string(table.exportSearchText),
                "sortDescriptors": .array([
                    .dictionary([
                        "key": .string(table.exportSortKey),
                        "ascending": .boolean(table.exportSortAscending),
                    ]),
                ]),
                "columnFilterComposition": .string(table.exportColumnFilterComposition.rawValue),
                "columnFilters": .array(table.exportColumnFilters.map(frozenColumnFilterParameter)),
                "metadataColumns": .array(metadata.exportHeaders.map { .string($0) }),
            ],
            runClock: runClock
        )) { outputURL in
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    private static func frozenSelectedSampleIds(
        view: EsVirituResultViewController,
        result: LungfishIO.EsVirituResult
    ) -> [String] {
        if view.isBatchMode, let samplePickerState = view.samplePickerState {
            return samplePickerState.selectedSamples.sorted()
        }
        let detectionSamples = Set(result.detections.map(\.sampleId))
        if !detectionSamples.isEmpty {
            return detectionSamples.sorted()
        }
        return result.sampleId == "batch" ? [] : [result.sampleId]
    }

    private static func frozenColumnFilterParameter(_ filter: ColumnFilter) -> ParameterValue {
        .dictionary([
            "columnId": .string(filter.columnId),
            "operator": .string(filter.op.rawValue),
            "operatorName": .string(String(describing: filter.op)),
            "value": .string(filter.value),
            "value2": filter.value2.map(ParameterValue.string) ?? .null,
            "inverted": .boolean(filter.isInverted),
        ])
    }

    private static func frozenSourceURLs(view: EsVirituResultViewController) -> [URL] {
        guard let batchURL = view.batchURL else { return [] }
        let writesMetadata = !view.testDetectionTableView.metadataColumns.exportHeaders.isEmpty
        let urls = [batchURL.appendingPathComponent(EsVirituDetectionExport.databaseFileName)]
            + EsVirituDetectionExport.metadataInputURLs(in: batchURL, writesMetadata: writesMetadata)
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Side C. The view's invocation and begin helper, which run the built CLI behind the row on the shared runner.
    private func sideC(_ root: URL, samples: Set<String>) async throws -> RouteParitySideOutcome {
        let view = try Self.configuredView(root, samples: samples)
        let result = try XCTUnwrap(view.esVirituResult)
        let invocation = try XCTUnwrap(view.detectionsExportInvocation(result: result, format: .tsv, outputURL: Self.outputURL(in: root)))
        let failures = EsVirituExportFailureCalls()
        guard let begun = EsVirituResultViewController.beginEsVirituDetectionsExportOperation(
            invocation: invocation,
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

    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on the compared facts, and the
    /// predicted record changes hold.
    @discardableResult
    private func assertParity(_ parityCase: Case, samples: Set<String>) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: Self.makeResult,
            sideA: { root in try self.sideA(root, samples: samples) },
            sideC: { root in try await self.sideC(root, samples: samples) }
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
        XCTAssertEqual(found[.cAgainstCPrime]?.map(\.description) ?? [], [], "C against C' declares nothing")
        try assertAEqualsC(runs)
        try assertPredictedRecordChanges(runs)
        return runs
    }

    /// A against C on the facts of 1.7, with each record path read relative to its side root. No file but the
    /// record differs, and the record's compared facts are equal.
    private func assertAEqualsC(_ runs: RouteParityRuns) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter { !$0.id.contains(sidecarName) }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payloadA = try Data(contentsOf: Self.outputURL(in: runs.a.root))
        XCTAssertEqual(payloadA, try Data(contentsOf: Self.outputURL(in: runs.c.root)), "the payload byte for byte")
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root), Self.inputs(of: c, under: runs.c.root), "inputs and digests")
        XCTAssertEqual(
            Self.inputs(of: c, under: runs.c.root).keys.sorted(),
            ["/esviritu-batch/esviritu.sqlite", "/esviritu-batch/metadata/sample_metadata.tsv"],
            "the database and the metadata table, never the batch manifest (G3)"
        )
        let outputA = try XCTUnwrap(a.output)
        let outputC = try XCTUnwrap(c.output)
        XCTAssertNotNil(outputA.checksumSHA256)
        XCTAssertEqual(outputA.checksumSHA256, outputC.checksumSHA256, "the output digest")
        XCTAssertEqual(outputA.fileSize, UInt64(payloadA.count))
        XCTAssertEqual(outputA.fileSize, outputC.fileSize, "the output size")
        let resolvedA = a.options.resolvedDefaults
        let resolvedC = c.options.resolvedDefaults
        XCTAssertEqual(Set(resolvedA.keys).intersection(resolvedC.keys), Self.sharedResolvedKeys)
        for key in Self.sharedResolvedKeys.sorted() {
            XCTAssertEqual(resolvedA[key], resolvedC[key], "resolved \(key)")
        }
    }

    /// The prediction rows of the lane report (BIO 7). The five identity fields move from the app's writer to the
    /// leaf, and the keys of state side A never applied are gone. The record's argv is the row's command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let outputA = Self.outputURL(in: runs.a.root)
        let argvA = ["Lungfish.app", "export-esviritu-detections", "--format", "tsv", "--output", outputA.path]
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, "lungfish app esviritu detections export")
        XCTAssertEqual(Set(a.options.resolvedDefaults.keys), Self.sharedResolvedKeys.union(Self.unappliedKeys))
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["format", "outputPath"])
        XCTAssertEqual(a.options.defaults["format"]?.stringValue, "tsv")

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, EsVirituDetectionExport.workflowName)
        XCTAssertEqual(Set(c.options.resolvedDefaults.keys), Self.sharedResolvedKeys)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["metadataColumns", "outputFormat", "outputPath", "samples"])
        XCTAssertEqual(c.options.explicit["outputFormat"]?.stringValue, "tsv")
        XCTAssertTrue(c.options.defaults.isEmpty)
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
