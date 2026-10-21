// Kraken2TableExportCLIGUIParityReplayTests.swift - The Kraken2 taxonomy table export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.33, ARCH ruling on the export shape 1.7 and on 12.33 F1 (C7), on lane Q30's harness. Each case
// runs on three sides that start as copies of one Kraken2 result folder. A sidecar case holds a run folder (the
// sidecar, its kreport and a taxon name with a comma and quotes). A database case holds a batch folder (a database
// of two samples with three tied species each, and a sample metadata table that gives them different groups).
//
// - Side A is the in-app writer, `writeDelimitedExport` and its helpers as the view held them at a5a6afc26 (with
//   the side A fixes of C1 to C3), frozen in this file since the lane deletes it from the view, run on a view
//   configured as the sidebar configures it.
// - Side C is the view's begin helper, `beginTaxonomyTableExportOperation`, with the invocation the view builds.
//   It begins the row and runs the built `lungfish-cli kraken2 export table` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares what 1.7 names, which is the payload byte for byte, the record's inputs with their digests,
// the output's digest and size, and the three `resolved` keys both sides write, with no file but the record
// differing. The identity fields and the option keys are prediction rows of the lane report (BIO 7), pinned on each
// side by `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks. Nothing is
// declared, so the old writer goes in the lane with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14). Every result folder sits at least five folders below the temporary folder, so the record's
// walk over the input's folders never lists the temporary folder itself (SCR/lanes/12.31/12.31-cancel.md).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class TaxonomyExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class Kraken2TableExportCLIGUIParityReplayTests: XCTestCase {
    /// A sidecar case exports a run folder through its one-sample tree. A database case exports a batch folder
    /// through the samples the picker holds.
    enum Case: String, Sendable {
        case sidecarQuotedNameCsv
        case sidecarQuotedNameTsv
        case sidecarFolderAlsoHoldingDatabase
        case databaseEverySample
        case databaseOneSampleOfTwo
        case databaseTwoSamplesWithMetadata

        var isSidecar: Bool {
            switch self {
            case .sidecarQuotedNameCsv, .sidecarQuotedNameTsv, .sidecarFolderAlsoHoldingDatabase: return true
            default: return false
            }
        }

        var format: ViewerExportDelimitedFormat {
            switch self {
            case .sidecarQuotedNameCsv, .databaseEverySample: return .csv
            default: return .tsv
            }
        }

        /// The samples the picker holds, for a database case.
        var samples: [String] {
            switch self {
            case .databaseOneSampleOfTwo: return ["sample-B"]
            case .databaseEverySample, .databaseTwoSamplesWithMetadata: return ["sample-A", "sample-B"]
            default: return []
            }
        }

        var showsMetadata: Bool { self == .databaseTwoSamplesWithMetadata }

        /// The files the leaf reads, below the side root, which are what the record names (BIO 6).
        var expectedInputs: [String] {
            if isSidecar {
                return ["/kraken2-run/classification-result.json", "/kraken2-run/classification.kreport"]
            }
            return ["/kraken2-batch/kraken2.sqlite"] + (showsMetadata ? ["/kraken2-batch/metadata/sample_metadata.tsv"] : [])
        }

        /// The sample ids the record names as the table's samples.
        var expectedSamples: [String] { isSidecar ? ["sample-run_R1"] : samples }

        /// The keys of `explicit` the leaf writes.
        var expectedExplicitKeys: [String] {
            var keys = ["outputFormat", "outputPath"]
            if !isSidecar { keys.append("samples") }
            if showsMetadata { keys.append("metadataColumns") }
            return keys.sorted()
        }
    }

    /// The `resolved` keys both sides write, compared value for value.
    static let sharedResolvedKeys: Set<String> = ["nodeCount", "outputByteCount", "selectedSamples"]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let runFolderName = "kraken2-run"
    static let batchFolderName = "kraken2-batch"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "kraken2-table-parity")
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

    // MARK: - The sidecar form

    /// C7. A taxon name with a comma and quotes, in CSV.
    func testSidecarFormWithAQuotedNameInCsvMatches() async throws {
        let runs = try await assertParity(.sidecarQuotedNameCsv)
        let content = try Self.content(runs.c.root, .sidecarQuotedNameCsv)
        XCTAssertTrue(content.contains("\"Candidatus \"\"Foo, bar\"\"\",Species,"), content)
    }

    /// C7. The same name in TSV, which leaves it as it is.
    func testSidecarFormWithAQuotedNameInTsvMatches() async throws {
        let runs = try await assertParity(.sidecarQuotedNameTsv)
        let content = try Self.content(runs.c.root, .sidecarQuotedNameTsv)
        XCTAssertTrue(content.contains("Candidatus \"Foo, bar\"\tSpecies\t"), content)
    }

    /// C7. The folder holds `kraken2.sqlite` too, which the sidebar would open. The view was configured from the
    /// sidecar, so the leaf gets the sidecar file, and the file picks the form.
    func testSidecarFormOnAFolderThatAlsoHoldsADatabaseMatches() async throws {
        let parityCase = Case.sidecarFolderAlsoHoldingDatabase
        let runs = try await assertParity(parityCase)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.folderURL(in: runs.c.root, parityCase).appendingPathComponent("kraken2.sqlite").path
        ))
        let argv = try Self.envelope(in: runs.c.root, parityCase).argv
        XCTAssertTrue(argv.contains { $0.hasSuffix("/classification-result.json") }, "\(argv)")
        XCTAssertFalse(argv.contains { $0.hasSuffix("kraken2.sqlite") }, "the command names the sidecar, not the database")
    }

    // MARK: - The database form

    /// C7. Every sample given, so the table is the merged tree. The tied species come out in tax id order under
    /// each sample, in the view's process (side A) and in the leaf's (sides C and C'), which proves C1 across
    /// processes.
    func testDatabaseFormWithEverySampleMatches() async throws {
        let parityCase = Case.databaseEverySample
        let runs = try await assertParity(parityCase)
        XCTAssertEqual(
            Self.tiedNames(try Self.content(runs.c.root, parityCase)),
            ["Tied alpha", "Tied beta", "Tied gamma", "Tied alpha", "Tied beta", "Tied gamma"]
        )
        XCTAssertEqual(try Self.envelope(in: runs.c.root, parityCase).argv.filter { $0 == "--sample" }.count, 2)
    }

    /// C7. A subset, so the command names one `--sample` and the table is that sample's own tree.
    func testDatabaseFormWithOneSampleOfTwoMatches() async throws {
        let parityCase = Case.databaseOneSampleOfTwo
        let runs = try await assertParity(parityCase)
        XCTAssertEqual(Self.tiedNames(try Self.content(runs.c.root, parityCase)), ["Tied alpha", "Tied beta", "Tied gamma"])
        let record = try Self.envelope(in: runs.c.root, parityCase)
        XCTAssertEqual(record.argv.filter { $0 == "--sample" }.count, 1)
        XCTAssertEqual(record.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-B"])
    }

    /// C7 and C3. Two samples and `Group` shown, so each sample's rows carry its own value and the Root row none.
    func testDatabaseFormWithTwoSamplesAndAMetadataColumnMatches() async throws {
        let parityCase = Case.databaseTwoSamplesWithMetadata
        let runs = try await assertParity(parityCase)
        let rows = try Self.content(runs.c.root, parityCase).split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.count, 14, "the header, Root, and two samples with five taxa each and an unclassified row each")
        var group = ""
        for row in rows.dropFirst() {
            XCTAssertEqual(row.count, 7, "every row is as long as the header: \(row)")
            if row[0] == "Root" {
                XCTAssertEqual(row.last, "")
                continue
            }
            if row[0] == "sample-A" { group = "case" }
            if row[0] == "sample-B" { group = "control" }
            XCTAssertEqual(row.last, group, "\(row)")
        }
        let columns = try Self.envelope(in: runs.c.root, parityCase).options.explicit["metadataColumns"]
        XCTAssertEqual(columns?.arrayValue?.compactMap(\.stringValue), ["Group"])
    }

    /// C7. The leaf given the result folder reads the database the sidebar would open, so its bytes are the file
    /// form's. The record names the same inputs.
    func testTheFolderFormWritesTheDatabaseFormsBytes() async throws {
        let parityCase = Case.databaseTwoSamplesWithMetadata
        let runs = try await assertParity(parityCase)
        var arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        let databaseIndex = try XCTUnwrap(arguments.firstIndex { $0.hasSuffix("/kraken2.sqlite") })
        arguments[databaseIndex] = Self.folderURL(in: runs.c.root, parityCase).path
        let databaseOutput = Self.outputURL(in: runs.c.root, parityCase)
        let outputIndex = try XCTUnwrap(arguments.firstIndex(of: databaseOutput.path))
        let folderOutput = runs.c.root.appendingPathComponent("taxonomy-from-folder.tsv")
        arguments[outputIndex] = folderOutput.path

        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60), environment: [:], cancelWhen: nil
        )
        XCTAssertEqual(run.end, .completed, run.detail)
        XCTAssertEqual(try Data(contentsOf: folderOutput), try Data(contentsOf: databaseOutput), "the folder form's bytes")
        let folderRecord = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: folderOutput)))
        let databaseRecord = try Self.envelope(in: runs.c.root, parityCase)
        XCTAssertEqual(
            Self.inputs(of: folderRecord, under: runs.c.root), Self.inputs(of: databaseRecord, under: runs.c.root),
            "the folder form reads the same files"
        )
        XCTAssertEqual(folderRecord.options.resolvedDefaults["selectedSamples"], databaseRecord.options.resolvedDefaults["selectedSamples"])
    }

    // MARK: - Cancel

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let parityCase = Case.databaseEverySample
        let root = scratch.appendingPathComponent("cancel/case/run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeResult(root, parityCase)
        let output = Self.outputURL(in: root, parityCase)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let view = try Self.configuredView(root, parityCase)
        let invocation = try XCTUnwrap(view.taxonomyExportInvocation(format: parityCase.format, outputURL: output))

        let failures = TaxonomyExportFailureCalls()
        let begun = try XCTUnwrap(TaxonomyViewController.beginTaxonomyTableExportOperation(
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

// MARK: - The fixtures and the view

extension Kraken2TableExportCLIGUIParityReplayTests {
    /// The output each side writes, in its root.
    static func outputURL(in root: URL, _ parityCase: Case) -> URL {
        root.appendingPathComponent("taxonomy.\(parityCase.format.rawValue)")
    }

    /// The result folder of the case below a side root.
    static func folderURL(in root: URL, _ parityCase: Case) -> URL {
        root.appendingPathComponent(parityCase.isSidecar ? runFolderName : batchFolderName, isDirectory: true)
    }

    static func envelope(in root: URL, _ parityCase: Case) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root, parityCase))
        ))
    }

    static func content(_ root: URL, _ parityCase: Case) throws -> String {
        try String(contentsOf: outputURL(in: root, parityCase), encoding: .utf8)
    }

    /// The names of the tied species in the order the table lists them, up to the first separator.
    static func tiedNames(_ content: String) -> [String] {
        content.split(separator: "\n").filter { $0.hasPrefix("Tied ") }
            .map { line in String(line.prefix { $0 != "," && $0 != "\t" }) }
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The result folder the sidebar item opens. A run folder holds the sidecar and its kreport. A batch folder holds
    /// the database and the sample metadata table. The folder of `sidecarFolderAlsoHoldingDatabase` holds both.
    static func makeResult(_ root: URL, _ parityCase: Case) throws {
        let folder = folderURL(in: root, parityCase)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if parityCase.isSidecar { try makeRun(folder) }
        if !parityCase.isSidecar || parityCase == .sidecarFolderAlsoHoldingDatabase { try makeBatch(folder) }
    }

    /// One run: an unclassified line, a root, one domain, a taxon whose name holds a comma and quotes, and three
    /// species with equal reads.
    private static func makeRun(_ folder: URL) throws {
        let report = folder.appendingPathComponent("classification.kreport")
        let lines = [
            " 20.00\t20\t20\tU\t0\tunclassified",
            " 80.00\t80\t10\tR\t1\troot",
            " 70.00\t70\t0\tD\t2\t  Bacteria",
            " 40.00\t40\t40\tS\t562\t    Candidatus \"Foo, bar\"",
            " 10.00\t10\t10\tS\t1001\t    Tied alpha",
            " 10.00\t10\t10\tS\t1002\t    Tied beta",
            " 10.00\t10\t10\tS\t1003\t    Tied gamma",
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        let config = ClassificationConfig(
            inputFiles: [folder.appendingPathComponent("sample-run_R1.fastq")],
            isPairedEnd: false,
            databaseName: "test-db",
            databasePath: folder.deletingLastPathComponent().appendingPathComponent("db"),
            outputDirectory: folder
        )
        try ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: report),
            reportURL: report,
            outputURL: folder.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        ).save(to: folder)
    }

    /// A database of two samples. Each holds a big taxon and three species with equal reads, inserted in an order
    /// that is not their tax id order, so the order the table lists them in is the tree's tie order (C1).
    private static func makeBatch(_ folder: URL) throws {
        let metadata = folder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var rows: [Kraken2ClassificationRow] = []
        for (sample, name, taxId, reads) in [("sample-A", "Candidatus \"Foo, bar\"", 40, 40), ("sample-B", "Virus B", 20, 20)] {
            let total = reads + 30
            rows.append(batchRow(sample, "root", 1, direct: 0, clade: total, total: total, parent: nil, depth: 0))
            rows.append(batchRow(sample, name, taxId, direct: reads, clade: reads, total: total, parent: 1, depth: 1))
            for (tiedId, tiedName) in [(300, "Tied gamma"), (100, "Tied alpha"), (200, "Tied beta")] {
                rows.append(batchRow(sample, tiedName, tiedId, direct: 10, clade: 10, total: total, parent: 1, depth: 1))
            }
        }
        try Kraken2Database.create(
            at: folder.appendingPathComponent(Kraken2TaxonomyTableExport.databaseFileName),
            rows: rows,
            metadata: [
                "total_reads_sample-A": "80", "total_reads_sample-B": "60",
                "unclassified_reads_sample-A": "10", "unclassified_reads_sample-B": "10",
            ]
        )
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
    }

    private static func batchRow(
        _ sample: String, _ name: String, _ taxId: Int, direct: Int, clade: Int, total: Int, parent: Int?, depth: Int
    ) -> Kraken2ClassificationRow {
        Kraken2ClassificationRow(
            sample: sample, taxonName: name, taxId: taxId, rank: depth == 0 ? "R" : "S",
            rankDisplayName: depth == 0 ? "Root" : "Species",
            readsDirect: direct, readsClade: clade, percentage: Double(clade) * 100 / Double(total),
            parentTaxId: parent, depth: depth
        )
    }

    /// A view configured as the sidebar configures it. A sidecar case loads the result from the run folder
    /// (`ClassificationResult.load`, as `MainSplitViewController+ClassifierDisplay` does). A database case opens
    /// the database, loads the sample metadata, shows `Group` when the case asks and picks the case's samples.
    static func configuredView(_ root: URL, _ parityCase: Case) throws -> TaxonomyViewController {
        let folder = folderURL(in: root, parityCase)
        let view = TaxonomyViewController()
        _ = view.view
        if parityCase.isSidecar {
            view.configure(result: try ClassificationResult.load(from: folder))
            return view
        }
        let database = try Kraken2Database(at: folder.appendingPathComponent(Kraken2TaxonomyTableExport.databaseFileName))
        view.configureFromDatabase(database)
        // The app's `applySampleMetadata` also refreshes the database's metadata cache, which rewrites
        // `kraken2.sqlite` and moves its digest on every open (lane report, finding 3). The columns come from the
        // same call the setter makes without that write, so the three sides read one database.
        view.testTableView.metadataColumns.persistenceKey = nil
        if parityCase.showsMetadata {
            view.testTableView.metadataColumns.isMultiSampleMode = true
            view.testTableView.metadataColumns.update(
                store: SampleMetadataStore.load(from: folder, knownSampleIds: ["sample-A", "sample-B"]),
                sampleId: "sample-A"
            )
            view.testTableView.metadataColumns.visibleColumns = ["Group"]
        }
        view.samplePickerState.selectedSamples = Set(parityCase.samples)
        view.testApplyBatchSampleFilter()
        XCTAssertEqual(view.testTableView.metadataColumns.exportHeaders, parityCase.showsMetadata ? ["Group"] : [])
        return view
    }
}

// MARK: - The sides and the comparison

extension Kraken2TableExportCLIGUIParityReplayTests {
    /// Side A. The in-app writer the view's Export ran before the leaf, frozen below.
    private func sideA(_ root: URL, _ parityCase: Case) throws -> RouteParitySideOutcome {
        let view = try Self.configuredView(root, parityCase)
        let output = Self.outputURL(in: root, parityCase)
        do {
            try Self.frozenWriteDelimitedExport(
                view: view, tree: try XCTUnwrap(view.tree), separator: parityCase.format.separator, to: output
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(output.lastPathComponent)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `writeDelimitedExport` and its helpers as `TaxonomyViewController` held them at a5a6afc26, reading the view
    /// through its test accessors. The database is the batch folder's, which the view's `batchURL` names.
    private static func frozenWriteDelimitedExport(
        view: TaxonomyViewController,
        tree: TaxonTree,
        separator: String,
        to url: URL
    ) throws {
        let runClock = ProvenanceRunClock()
        let content = try frozenBuildDelimitedExport(view: view, tree: tree, separator: separator)
        let sourceURLs = frozenExportSourceURLs(view: view)
        let fileExtension = url.pathExtension.isEmpty ? "csv" : url.pathExtension
        let separatorName = separator == "\t" ? "tsv" : "csv"
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app taxonomy table export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: sourceURLs,
            outputURL: url,
            outputFormat: .text,
            argv: [
                CLICommandIdentity.executableName,
                "export", "taxonomy-table",
                "--separator", separatorName,
                "--output", url.path,
            ],
            explicitOptions: [
                "sourcePaths": .array(sourceURLs.map { .file($0) }),
                "outputPath": .file(url),
                "separator": .string(separatorName),
            ],
            defaults: [
                "outputFormat": .string(fileExtension),
            ],
            resolved: [
                "nodeCount": .integer(tree.allNodes().count),
                "outputByteCount": .integer(content.utf8.count),
                "selectedSamples": .array(frozenSelectedSampleIds(view: view).map(ParameterValue.string)),
            ],
            runClock: runClock
        )) { staged in
            try content.write(to: staged, atomically: true, encoding: .utf8)
        }
    }

    /// Phase 2.13 lane 13.35, BIO-R1 item 3. The writer takes each picked sample's own tree. A database view fetches
    /// them from the view's database as `renderBatchSelection` does, and a sidecar view holds the one tree it shows.
    private static func frozenBuildDelimitedExport(
        view: TaxonomyViewController, tree: TaxonTree, separator: String
    ) throws -> String {
        let metadata = view.testTableView.metadataColumns
        let selected = frozenSelectedSampleIds(view: view)
        let sampleTrees: [(sampleId: String, tree: TaxonTree)]
        if view.testClassificationResult == nil, let batchURL = view.batchURL {
            let database = try Kraken2Database(
                at: batchURL.appendingPathComponent(Kraken2TaxonomyTableExport.databaseFileName)
            )
            sampleTrees = try selected.map { (sampleId: $0, tree: try database.fetchTree(sample: $0)) }
        } else {
            sampleTrees = selected.map { (sampleId: $0, tree: tree) }
        }
        return Kraken2TaxonomyTableExport.buildDelimitedExport(
            sampleTrees: sampleTrees,
            separator: separator,
            metadataHeaders: metadata.exportHeaders,
            metadataValuesBySample: Dictionary(
                sampleTrees.map { ($0.sampleId, metadata.exportValues(for: $0.sampleId)) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    private static func frozenExportSourceURLs(view: TaxonomyViewController) -> [URL] {
        let writesMetadata = !view.testTableView.metadataColumns.exportHeaders.isEmpty
        var urls: [URL] = []
        if let result = view.testClassificationResult {
            let folder = result.config.outputDirectory
            urls = Kraken2TaxonomyTableExport.sidecarInputURLs(folder: folder, result: result)
                + Kraken2TaxonomyTableExport.metadataInputURLs(in: folder, writesMetadata: writesMetadata)
        } else if let batchURL = view.batchURL {
            urls = [batchURL.appendingPathComponent(Kraken2TaxonomyTableExport.databaseFileName)]
                + Kraken2TaxonomyTableExport.metadataInputURLs(in: batchURL, writesMetadata: writesMetadata)
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func frozenSelectedSampleIds(view: TaxonomyViewController) -> [String] {
        guard let result = view.testClassificationResult else {
            return view.samplePickerState?.selectedSamples.sorted() ?? []
        }
        return [Kraken2TaxonomyTableExport.sidecarSampleId(config: result.config)]
    }

    /// Side C. The view's invocation and begin helper, which run the built CLI behind the row on the shared runner.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let view = try Self.configuredView(root, parityCase)
        let invocation = try XCTUnwrap(
            view.taxonomyExportInvocation(format: parityCase.format, outputURL: Self.outputURL(in: root, parityCase))
        )
        let failures = TaxonomyExportFailureCalls()
        guard let begun = TaxonomyViewController.beginTaxonomyTableExportOperation(
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
            in: scratch.appendingPathComponent("cases/\(parityCase.rawValue)", isDirectory: true),
            fixture: { root in try Self.makeResult(root, parityCase) },
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
        try assertAEqualsC(runs, parityCase)
        try assertPredictedRecordChanges(runs, parityCase)
        return runs
    }

    /// A against C on the facts of 1.7, with each record path read relative to its side root. No file but the
    /// record differs, and the record's compared facts are equal.
    private func assertAEqualsC(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root, parityCase)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter { !$0.id.contains(sidecarName) }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payloadA = try Data(contentsOf: Self.outputURL(in: runs.a.root, parityCase))
        XCTAssertEqual(payloadA, try Data(contentsOf: Self.outputURL(in: runs.c.root, parityCase)), "the payload byte for byte")
        let a = try Self.envelope(in: runs.a.root, parityCase)
        let c = try Self.envelope(in: runs.c.root, parityCase)
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root), Self.inputs(of: c, under: runs.c.root), "inputs and digests")
        XCTAssertEqual(
            Self.inputs(of: c, under: runs.c.root).keys.sorted(), parityCase.expectedInputs.sorted(),
            "the files the leaf read, never the reads the run classified (BIO 6)"
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
        XCTAssertEqual(resolvedC["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), parityCase.expectedSamples)
    }

    /// The prediction rows of the lane report (BIO 7). The identity fields move from the app's writer to the leaf,
    /// `explicit` and `defaults` change with them, and the record's argv is the row's command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root, parityCase)
        let c = try Self.envelope(in: runs.c.root, parityCase)
        let outputA = Self.outputURL(in: runs.a.root, parityCase)
        let format = parityCase.format.rawValue
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(
            a.argv,
            [CLICommandIdentity.executableName, "export", "taxonomy-table", "--separator", format, "--output", outputA.path]
        )
        XCTAssertEqual(a.durableReplayArgv ?? a.argv, a.argv)
        XCTAssertEqual(a.workflowName, "lungfish app taxonomy table export")
        XCTAssertEqual(Set(a.options.resolvedDefaults.keys), Self.sharedResolvedKeys)
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["outputPath", "separator", "sourcePaths"])
        XCTAssertEqual(a.options.defaults["outputFormat"]?.stringValue, format)

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, Kraken2TaxonomyTableExport.workflowName)
        XCTAssertEqual(Set(c.options.resolvedDefaults.keys), Self.sharedResolvedKeys)
        XCTAssertEqual(c.options.explicit.keys.sorted(), parityCase.expectedExplicitKeys)
        XCTAssertEqual(c.options.explicit["outputFormat"]?.stringValue, format)
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
