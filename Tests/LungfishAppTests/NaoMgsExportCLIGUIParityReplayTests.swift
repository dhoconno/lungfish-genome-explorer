// NaoMgsExportCLIGUIParityReplayTests.swift - The NAO-MGS table export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M4, ARCH ruling on the export shape 1.7, BIO ruling on 12.31 M4 and the manager's answers to
// Q1 and Q2 of 12.31 c6, on lane Q30's harness and the recipe of the EsViritu class. Each case runs on three sides
// that start as copies of one root, which holds the import's source file `virus_hits.tsv` and the NAO-MGS result
// folder the sidebar item opens, with `hits.sqlite` of three samples, `manifest.json` and a sample metadata table.
//
// - Side A is the in-app writer, `writeSummaryTSV` as the view held it at d702ab9a7 with the Q1 and Q2 fixes, frozen
//   in this file since the lane deletes it from the view, run on a view opened as the app opens it
//   (`configure(database:manifest:bundleURL:)`) with the case's view state.
// - Side C is the view's begin helper, `beginNaoMgsTableExportOperation`, with the invocation the view builds
//   (`tableExportInvocation(outputURL:)`). It begins the row and runs the built `lungfish-cli nao-mgs export table`
//   on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares what 1.7 names, which is the payload byte for byte, the record's inputs with their digests,
// the output's digest and size, and every `resolved` key both sides write, `sortKeys` among them, with no file but
// the record differing. The five identity fields, the `explicit` and `defaults` parts and the `searchText` key only
// the leaf writes are prediction rows of the lane report (BIO 7), pinned on each side by
// `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks. Nothing is declared,
// so the old writer goes in the lane with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import AppKit
import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishNaoMgsUI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class NaoMgsExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class NaoMgsExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        /// Samples A and B picked, a search, `hits >= 2`, hits ascending and `Cohort` shown.
        case shownRowsWithMetadataColumn
        /// Every sample, a filter on the `Cohort` metadata column and no column shown (Q2 of c6).
        case metadataFilterWithNoColumnShown
    }

    /// The `resolved` keys both sides write, compared value for value.
    static let sharedResolvedKeys: Set<String> = [
        "columnFilterComposition", "columnFilters", "metadataColumns", "rowCount", "sampleName", "selectedSamples",
        "sortKeys", "sourceSampleCount",
    ]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"

    private var scratch: URL!
    private var harness: RouteParityHarness!
    /// The NAO-MGS column layout keys the standard defaults held when the case began (review 12.31-M4 Fix 2).
    private var layoutKeysBefore: Set<String> = []

    override func setUpWithError() throws {
        layoutKeysBefore = Self.standardLayoutKeys()
        NaoMgsResultViewController.testMetadataUserDefaultsOverride =
            makeTestDefaultsSuite(prefix: "NaoMgsExportCLIGUIParityReplayTests").defaults
        scratch = try TestTempDirectory.make(prefix: "naomgs-export-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        NaoMgsResultViewController.testMetadataUserDefaultsOverride = nil
        TestTempDirectory.cleanup(scratch)
        XCTAssertEqual(
            Self.standardLayoutKeys(), layoutKeysBefore,
            "the case left a NAO-MGS column layout in the standard defaults"
        )
    }

    /// The NAO-MGS column layout keys in `UserDefaults.standard`. A view opened on a result folder persists its
    /// layout under a key built from the folder's path, so a case that does not override the defaults leaves one.
    private static func standardLayoutKeys() -> Set<String> {
        Set(UserDefaults.standard.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("org.lungfish.metadata-column-layout.naomgs")
        })
    }

    /// The view's search, filter, sort, selection and metadata column reach the bytes on both sides.
    func testShownRowsWithMetadataColumnMatch() async throws {
        let runs = try await assertParity(.shownRowsWithMetadataColumn)
        let lines = try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.dropFirst().map { $0.split(separator: "\t").prefix(2).joined(separator: ":") }, [
            "sample-B:4", "sample-A:1", "sample-A:2",
        ])
        XCTAssertEqual(lines.dropFirst().map { $0.split(separator: "\t").last.map(String.init) }, [
            "control", "case", "case",
        ])
        let resolved = try Self.envelope(in: runs.c.root).options.resolvedDefaults
        XCTAssertEqual(resolved["sortKeys"]?.arrayValue?.compactMap(\.stringValue), ["hits:ascending"])
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-A", "sample-B"])
    }

    /// Manager's answer to Q2 of 12.31 c6. A filter on a metadata column reads the metadata table on both sides,
    /// so both records name it, though no column is shown.
    func testMetadataFilterWithNoColumnShownMatches() async throws {
        let runs = try await assertParity(.metadataFilterWithNoColumnShown)
        let lines = try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first?.hasSuffix("\taccession_count"), true, "no metadata column, \(lines)")
        XCTAssertEqual(Set(lines.dropFirst().compactMap { $0.split(separator: "\t").first.map(String.init) }), [
            "sample-A", "sample-C",
        ])
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        // Before it stages, the leaf's record looks for a sidecar of each input in the input's folder and the four
        // folders above it, and lists each one (`ProvenanceRecorder.findProvenanceReading`). Two more levels keep
        // that walk inside this case's folders. From `scratch/cancel` it reached the shared temporary folder, whose
        // listing (135,212 entries) took the leaf 20 to 40 seconds to reach its hold, past the 30 second wait.
        let root = scratch.appendingPathComponent("cancel/case/run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeResult(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let view = try Self.configuredView(root, .shownRowsWithMetadataColumn)
        let invocation = try XCTUnwrap(view.tableExportInvocation(outputURL: output))

        let failures = NaoMgsExportFailureCalls()
        let begun = try XCTUnwrap(NaoMgsResultViewController.beginNaoMgsTableExportOperation(
            invocation: invocation, runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
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

extension NaoMgsExportCLIGUIParityReplayTests {
    static let resultFolderName = "naomgs-result"
    static let sampleIds = ["sample-A", "sample-B", "sample-C"]

    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent("summary.tsv")
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The import's source file, which no payload byte comes from (BIO ruling on 12.31 M4), and the result folder
    /// the sidebar item opens, with its database of three samples, its manifest and the sample metadata table.
    static func makeResult(_ root: URL) throws {
        let source = root.appendingPathComponent("virus_hits.tsv")
        try Data("source\n".utf8).write(to: source)
        let result = root.appendingPathComponent(resultFolderName, isDirectory: true)
        let metadata = result.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(NaoMgsManifest(
            sampleName: "naomgs-parity", sourceFilePath: source.path, hitCount: 15, taxonCount: 5,
            topTaxon: "Taxon 2", topTaxonId: 2
        )).write(to: result.appendingPathComponent(NaoMgsSummaryExport.manifestFileName))
        let counts: [(sample: String, taxId: Int, hits: Int)] = [
            ("sample-A", 1, 3), ("sample-A", 2, 5), ("sample-A", 3, 1), ("sample-B", 4, 2), ("sample-C", 5, 4),
        ]
        try NaoMgsDatabase.create(
            at: result.appendingPathComponent(NaoMgsSummaryExport.databaseFileName),
            hits: counts.flatMap { entry in
                (0..<entry.hits).map { hit(sample: entry.sample, taxId: entry.taxId, read: $0) }
            }
        )
        try Data("Sample\tCohort\nsample-A\tcase\nsample-B\tcontrol\nsample-C\tcase\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
    }

    private static func hit(sample: String, taxId: Int, read: Int) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample, seqId: "\(sample)-\(taxId)-\(read)", taxId: taxId,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100, refStart: read * 100,
            refEnd: read * 100 + 100, readSequence: String(repeating: "A", count: 100),
            readQuality: String(repeating: "I", count: 100), subjectSeqId: "NC_\(taxId)", subjectTitle: "Taxon \(taxId)",
            bitScore: 210, eValue: 1e-40, percentIdentity: 99, editDistance: 1, fragmentLength: 100,
            isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
    }

    /// A view opened as the app's database route opens it (`MainSplitViewController+ClassifierDisplay.swift`), with
    /// the sample metadata the app loads and the case's view state.
    static func configuredView(_ root: URL, _ parityCase: Case) throws -> NaoMgsResultViewController {
        let resultURL = root.appendingPathComponent(resultFolderName, isDirectory: true)
        let database = try NaoMgsDatabase(at: resultURL.appendingPathComponent(NaoMgsSummaryExport.databaseFileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            NaoMgsManifest.self,
            from: Data(contentsOf: resultURL.appendingPathComponent(NaoMgsSummaryExport.manifestFileName))
        )
        let view = NaoMgsResultViewController()
        view.loadViewIfNeeded()
        view.configure(database: database, manifest: manifest, bundleURL: resultURL)
        view.applySampleMetadata(SampleMetadataStore.load(from: resultURL, knownSampleIds: Set(sampleIds)))
        switch parityCase {
        case .shownRowsWithMetadataColumn:
            view.metadataColumnController.visibleColumns = ["Cohort"]
            view.testSetTaxonomySearchText("sample")
            view.columnHeaderFilterMenu(
                replaceFilterFor: "hits", with: ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "2")
            )
            view.columnHeaderFilterMenuFiltersDidChange()
            view.columnHeaderFilterMenu(sortByKey: "hits", ascending: true)
            view.samplePickerState.selectedSamples = ["sample-A", "sample-B"]
            view.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
            XCTAssertEqual(view.testDisplayedTaxonOrder, ["sample-B:4", "sample-A:1", "sample-A:2"])
        case .metadataFilterWithNoColumnShown:
            view.metadataColumnController.visibleColumns = []
            view.columnHeaderFilterMenu(
                replaceFilterFor: "metadata_Cohort",
                with: ColumnFilter(columnId: "metadata_Cohort", op: .contains, value: "case")
            )
            view.columnHeaderFilterMenuFiltersDidChange()
            XCTAssertEqual(Set(view.testDisplayedTaxonOrder.map { String($0.prefix { $0 != ":" }) }), ["sample-A", "sample-C"])
        }
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
    private func sideA(_ root: URL, _ parityCase: Case) throws -> RouteParitySideOutcome {
        let view = try Self.configuredView(root, parityCase)
        do {
            try Self.frozenWriteSummaryTSV(view: view, to: Self.outputURL(in: root))
            return RouteParitySideOutcome(end: .completed, detail: "Exported summary.tsv")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    private struct FrozenNoRows: Error {}

    /// `writeSummaryTSV` and its helpers as `NaoMgsResultViewController` held them at d702ab9a7, with the Q1 and Q2
    /// fixes, reading the view through `testTableExportWriterState` and its other test accessors.
    private static func frozenWriteSummaryTSV(view: NaoMgsResultViewController, to url: URL) throws {
        let state = view.testTableExportWriterState
        guard !state.rows.isEmpty else { throw FrozenNoRows() }
        let runClock = ProvenanceRunClock()
        let metadata = view.metadataColumnController
        let content = NaoMgsSummaryExport.summaryTSV(
            rows: state.rows,
            metadataHeaders: metadata.exportHeaders,
            metadataValuesBySample: Dictionary(uniqueKeysWithValues: Set(state.rows.map(\.sample)).map {
                ($0, metadata.exportValues(for: $0))
            })
        )
        let selected = state.selectedSamples.isEmpty
            ? Array(Set(state.rows.map(\.sample))).sorted()
            : state.selectedSamples.sorted()
        let sortKeys = view.testTaxonomyTableView.sortDescriptors.first.flatMap { descriptor in
            descriptor.key.map { [ViewerExportSortKey(column: $0, ascending: descriptor.ascending)] }
        } ?? []
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app naomgs summary export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: frozenSourceURLs(view: view, filters: state.filters, databaseURL: state.databaseURL),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-naomgs-summary", "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string("tsv"),
            ],
            defaults: [
                "format": .string("tsv"),
            ],
            resolved: [
                "rowCount": .integer(state.rows.count),
                "sourceSampleCount": .integer(max(view.sampleEntries.count, selected.count)),
                "selectedSamples": .array(selected.map { .string($0) }),
                "columnFilterComposition": .string(state.filters.composition.rawValue),
                "columnFilters": .array(state.filters.activeFilters.map(frozenColumnFilterParameter)),
                "sortKeys": .array(sortKeys.map { .string($0.argument) }),
                "metadataColumns": .array(metadata.exportHeaders.map { .string($0) }),
                "sampleName": .string(state.sampleName ?? "naomgs"),
            ],
            runClock: runClock
        )) { outputURL in
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
        }
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

    private static func frozenSourceURLs(
        view: NaoMgsResultViewController,
        filters: ColumnFilterSet,
        databaseURL: URL?
    ) -> [URL] {
        var urls: [URL] = []
        if let databaseURL {
            urls.append(databaseURL)
        }
        if let bundleURL = view.bundleURL {
            urls.append(bundleURL.appendingPathComponent("manifest.json"))
            let metadata = view.metadataColumnController
            let readsMetadata = metadata.store != nil && (
                !metadata.exportHeaders.isEmpty
                    || filters.activeFilters.contains { $0.columnId.hasPrefix("metadata_") }
            )
            urls += EsVirituDetectionExport.metadataInputURLs(in: bundleURL, writesMetadata: readsMetadata)
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Side C. The view's invocation and begin helper, which run the built CLI behind the row on the shared runner.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let view = try Self.configuredView(root, parityCase)
        let invocation = try XCTUnwrap(view.tableExportInvocation(outputURL: Self.outputURL(in: root)))
        let failures = NaoMgsExportFailureCalls()
        guard let begun = NaoMgsResultViewController.beginNaoMgsTableExportOperation(
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
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: Self.makeResult,
            sideA: { root in try self.sideA(root, parityCase) },
            sideC: { root in try await self.sideC(root, parityCase) }
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
        try assertPredictedRecordChanges(runs, parityCase)
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
        XCTAssertFalse(Self.inputs(of: c, under: runs.c.root).values.contains("no digest"), "every input has a digest")
        XCTAssertEqual(
            Self.inputs(of: c, under: runs.c.root).keys.sorted(),
            ["/naomgs-result/hits.sqlite", "/naomgs-result/manifest.json", "/naomgs-result/metadata/sample_metadata.tsv"],
            "the database, the manifest and the metadata table, never the import's source file (M4-2)"
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
    /// leaf, the leaf records the search it applies, and its `explicit` part names the options the row passed. The
    /// record's argv is the row's command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let outputA = Self.outputURL(in: runs.a.root)
        let argvA = ["Lungfish.app", "export-naomgs-summary", "--output", outputA.path]
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, "lungfish app naomgs summary export")
        XCTAssertEqual(Set(a.options.resolvedDefaults.keys), Self.sharedResolvedKeys)
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["format", "outputPath"])
        XCTAssertEqual(a.options.defaults, ["format": .string("tsv")])

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, NaoMgsSummaryExport.workflowName)
        XCTAssertEqual(c.options.defaults, [:])
        let sorts = rowArguments.contains("--sort") ? ["sortKeys"] : []
        switch parityCase {
        case .shownRowsWithMetadataColumn:
            XCTAssertEqual(Set(c.options.resolvedDefaults.keys), Self.sharedResolvedKeys.union(["searchText"]))
            XCTAssertEqual(c.options.resolvedDefaults["searchText"]?.stringValue, "sample")
            XCTAssertEqual(c.options.explicit.keys.sorted(), [
                "filterMatch", "filters", "metadataColumns", "outputPath", "samples", "searchText", "sortKeys",
            ])
        case .metadataFilterWithNoColumnShown:
            XCTAssertEqual(Set(c.options.resolvedDefaults.keys), Self.sharedResolvedKeys)
            XCTAssertEqual(c.options.explicit.keys.sorted(), (["filterMatch", "filters", "outputPath", "samples"] + sorts).sorted())
        }
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
