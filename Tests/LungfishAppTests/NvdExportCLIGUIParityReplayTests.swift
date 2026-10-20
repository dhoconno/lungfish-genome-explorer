// NvdExportCLIGUIParityReplayTests.swift - The NVD contigs export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M4, ARCH ruling on the export shape 1.7 and BIO ruling on 12.31 M4, on lane Q30's harness and
// the recipe of the NAO-MGS class. Each case runs on three sides that start as copies of one root, which holds the
// run folder the import read, `nvd-run`, and the NVD result folder the sidebar item opens, with `hits.sqlite` of three
// samples, `manifest.json` and a sample metadata table.
//
// - Side A is the in-app writer, `writeContigsTSV` as the view held it at cad519f3b, frozen in this file since the
//   lane deletes it from the view, run on a view opened as the app opens it
//   (`configure(database:manifest:bundleURL:)`) with the case's view state.
// - Side C is the view's begin helper, `beginNvdContigsExportOperation`, with the invocation the view builds
//   (`contigsExportInvocation(outputURL:)`). It begins the row and runs the built `lungfish-cli nvd export contigs`
//   on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares what 1.7 names, which is the payload byte for byte, the record's inputs with their digests,
// the output's digest and size, and the six `resolved` keys both sides write, with no file but the record differing.
// The five identity fields, the `explicit` and `defaults` parts and side A's `groupingMode` and `taxonGroupCount`,
// which describe the outline and never reach the bytes (BIO 4), are prediction rows of the lane report (BIO 7),
// pinned on each side by `assertPredictedRecordChanges`. C against C' compares everything under the contract's
// masks. Nothing is declared, so the old writer goes in the lane with no key (R-A1, C4).
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
@testable import LungfishNvdUI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class NvdExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class NvdExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        /// Samples 1 and 2 picked, the search `virus`, an outline sort and `Cohort` shown.
        case shownRowsWithMetadataColumn
        /// Every sample, no search and the sample metadata loaded with no column shown.
        case everySampleWithNoColumnShown
    }

    /// The `resolved` keys both sides write, compared value for value.
    static let sharedResolvedKeys: Set<String> = [
        "experiment", "metadataColumns", "rowCount", "searchQuery", "selectedSamples", "sourceSampleCount",
    ]
    /// The keys only side A writes. They describe the outline's grouping and never change the bytes (BIO 4).
    static let unappliedKeys: Set<String> = ["groupingMode", "taxonGroupCount"]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        NvdResultViewController.testMetadataUserDefaultsOverride =
            makeTestDefaultsSuite(prefix: "NvdExportCLIGUIParityReplayTests").defaults
        scratch = try TestTempDirectory.make(prefix: "nvd-export-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        NvdResultViewController.testMetadataUserDefaultsOverride = nil
        TestTempDirectory.cleanup(scratch)
    }

    /// The view's selection, search and metadata column reach the bytes on both sides, and its outline sort does not.
    func testShownRowsWithMetadataColumnMatch() async throws {
        let runs = try await assertParity(.shownRowsWithMetadataColumn)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8), [
            "sample_id\tcontig\tlength\tclassification\trank\taccession\tsubject\tpident\tevalue\tbitscore\tmapped_reads\treads_per_billion\tCohort",
            "sample1\tcontig_1\t8\tAlpha virus\tspecies\tNC_sample1_contig_1\tAlpha virus\t100.00\t0.0\t50.0\t30\t30000000\tcase",
            "sample2\tcontig_1\t8\tGamma virus\tspecies\tNC_sample2_contig_1\tGamma virus\t100.00\t0.0\t50.0\t20\t20000000\tcontrol",
        ].joined(separator: "\n") + "\n")
        let resolved = try Self.envelope(in: runs.c.root).options.resolvedDefaults
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample1", "sample2"])
        XCTAssertEqual(resolved["searchQuery"]?.stringValue, "virus")
    }

    /// Every sample with no column shown writes every best hit and names neither metadata file on either side (M4-2).
    func testEverySampleWithNoColumnShownMatches() async throws {
        let runs = try await assertParity(.everySampleWithNoColumnShown)
        let lines = try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first?.hasSuffix("\treads_per_billion"), true, "no metadata column, \(lines)")
        XCTAssertEqual(lines.dropFirst().map { $0.split(separator: "\t").prefix(2).joined(separator: ":") }, [
            "sample1:contig_1", "sample1:contig_2", "sample2:contig_1", "sample3:contig_1",
        ])
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        // Before it stages, the leaf's record looks for a sidecar of each input in the input's folder and the four
        // folders above it, and lists each one (`ProvenanceRecorder.findProvenanceReading`). Two more levels keep
        // that walk inside this case's folders. From `scratch/cancel` it reached the shared temporary folder, whose
        // listing (135,212 entries) took the leaf 20 to 40 seconds to reach its hold, past the 30 second wait. The
        // NAO-MGS twin made the same move in lane 12.31.
        let root = scratch.appendingPathComponent("cancel/case/run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeResult(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let view = try Self.configuredView(root, .shownRowsWithMetadataColumn)
        let invocation = try XCTUnwrap(view.contigsExportInvocation(outputURL: output))

        let failures = NvdExportFailureCalls()
        let begun = try XCTUnwrap(NvdResultViewController.beginNvdContigsExportOperation(
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

extension NvdExportCLIGUIParityReplayTests {
    static let resultFolderName = "nvd-result"
    static let sampleIds = ["sample1", "sample2", "sample3"]

    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent("contigs.tsv")
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The run folder the import read, which no payload byte comes from (BIO ruling on 12.31 M4, M4-3), and the
    /// result folder the sidebar item opens, with its database of three samples, its manifest and the metadata table.
    static func makeResult(_ root: URL) throws {
        let runFolder = root.appendingPathComponent("nvd-run", isDirectory: true)
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        try Data("run\n".utf8).write(to: runFolder.appendingPathComponent("blast_concatenated.csv"))
        let result = root.appendingPathComponent(resultFolderName, isDirectory: true)
        let metadata = result.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try NvdDatabase.create(
            at: result.appendingPathComponent(NvdContigsExport.databaseFileName),
            hits: [
                hit(sample: "sample1", contig: "contig_1", name: "Alpha virus", reads: 30),
                hit(sample: "sample1", contig: "contig_2", name: "Beta phage", reads: 50),
                hit(sample: "sample2", contig: "contig_1", name: "Gamma virus", reads: 20),
                hit(sample: "sample3", contig: "contig_1", name: "Alpha virus", reads: 40),
            ],
            samples: sampleIds.map {
                NvdSampleMetadata(
                    sampleId: $0, bamPath: "\($0).bam", fastaPath: "\($0).fasta",
                    totalReads: 1000, contigCount: 1, hitCount: 1
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(NvdManifest(
            experiment: "exp-parity", sampleCount: 3, contigCount: 4, hitCount: 4, blastDbVersion: "db",
            snakemakeRunId: "run-1", sourceDirectoryPath: runFolder.path,
            samples: sampleIds.map {
                NvdSampleSummary(
                    sampleId: $0, contigCount: 1, hitCount: 1, totalReads: 1000,
                    bamRelativePath: "\($0).bam", fastaRelativePath: "\($0).fasta"
                )
            },
            cachedTopContigs: nil
        )).write(to: result.appendingPathComponent(NvdContigsExport.manifestFileName))
        try Data("Sample\tCohort\nsample1\tcase\nsample2\tcontrol\nsample3\tcase\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
    }

    private static func hit(sample: String, contig: String, name: String, reads: Int) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-parity", blastTask: "blastn", sampleId: sample, qseqid: contig, qlen: 8,
            sseqid: "NC_\(sample)_\(contig)", stitle: name, taxRank: "species", length: 8, pident: 100, evalue: 0,
            bitscore: 50, sscinames: name, staxids: "1234", blastDbVersion: "db", snakemakeRunId: "run-1",
            mappedReads: reads, totalReads: 1000, statDbVersion: "stats-1", adjustedTaxid: "1234",
            adjustmentMethod: "dominant", adjustedTaxidName: name, adjustedTaxidRank: "species", hitRank: 1,
            readsPerBillion: Double(reads) * 1_000_000
        )
    }

    /// A view opened as the app's database route opens it (`MainSplitViewController+ClassifierDisplay.swift`), with
    /// the sample metadata the app loads and the case's view state.
    static func configuredView(_ root: URL, _ parityCase: Case) throws -> NvdResultViewController {
        let resultURL = root.appendingPathComponent(resultFolderName, isDirectory: true)
        let database = try NvdDatabase(at: resultURL.appendingPathComponent(NvdContigsExport.databaseFileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            NvdManifest.self,
            from: Data(contentsOf: resultURL.appendingPathComponent(NvdContigsExport.manifestFileName))
        )
        let view = NvdResultViewController()
        view.loadViewIfNeeded()
        view.configure(database: database, manifest: manifest, bundleURL: resultURL)
        let store = try XCTUnwrap(SampleMetadataStore.load(from: resultURL, knownSampleIds: Set(sampleIds)))
        view.applySampleMetadata(store)
        switch parityCase {
        case .shownRowsWithMetadataColumn:
            view.testShowMetadataColumn("Cohort", store: store)
            view.testSearchField.stringValue = "virus"
            _ = view.testSearchField.target?.perform(view.testSearchField.action, with: view.testSearchField)
            view.testOutlineView.sortDescriptors = [NSSortDescriptor(key: "mappedReads", ascending: true)]
            view.samplePickerState.selectedSamples = ["sample1", "sample2"]
            view.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
            XCTAssertEqual(view.searchQuery, "virus")
        case .everySampleWithNoColumnShown:
            XCTAssertEqual(view.metadataColumnController.exportHeaders, [])
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
            try Self.frozenWriteContigsTSV(view: view, to: Self.outputURL(in: root))
            return RouteParitySideOutcome(end: .completed, detail: "Exported contigs.tsv")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `writeContigsTSV` and its helpers as `NvdResultViewController` held them at cad519f3b, reading the view
    /// through `testContigsExportWriterState` and the members its begin helper reads.
    private static func frozenWriteContigsTSV(view: NvdResultViewController, to url: URL) throws {
        let state = view.testContigsExportWriterState
        let runClock = ProvenanceRunClock()
        let metadata = view.metadataColumnController
        let content = NvdContigsExport.contigsTSV(
            hits: state.hits,
            metadataHeaders: metadata.exportHeaders,
            metadataValuesBySample: Dictionary(uniqueKeysWithValues: Set(state.hits.map(\.sampleId)).map {
                ($0, metadata.exportValues(for: $0))
            })
        )
        let groupingModeName: String
        switch view.groupingMode {
        case .bySample: groupingModeName = "bySample"
        case .byTaxon: groupingModeName = "byTaxon"
        }
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app nvd contigs export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: frozenSourceURLs(view: view, databaseURL: state.databaseURL),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-nvd-contigs", "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string("tsv"),
            ],
            defaults: [
                "format": .string("tsv"),
            ],
            resolved: [
                "rowCount": .integer(state.hits.count),
                "experiment": .string(state.experiment ?? "nvd"),
                "sourceSampleCount": .integer(view.sampleEntries.count),
                "selectedSamples": .array(view.selectedSamples.sorted().map { .string($0) }),
                "searchQuery": .string(view.searchQuery),
                "groupingMode": .string(groupingModeName),
                "taxonGroupCount": .integer(state.taxonGroupCount),
                "metadataColumns": .array(metadata.exportHeaders.map { .string($0) }),
            ],
            runClock: runClock
        )) { outputURL in
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    private static func frozenSourceURLs(view: NvdResultViewController, databaseURL: URL?) -> [URL] {
        var urls: [URL] = []
        if let databaseURL {
            urls.append(databaseURL)
        }
        if let bundleURL = view.bundleURL {
            urls.append(bundleURL.appendingPathComponent("manifest.json"))
            let writesMetadata = !view.metadataColumnController.exportHeaders.isEmpty
            urls += EsVirituDetectionExport.metadataInputURLs(in: bundleURL, writesMetadata: writesMetadata)
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Side C. The view's invocation and begin helper, which run the built CLI behind the row on the shared runner.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let view = try Self.configuredView(root, parityCase)
        let invocation = try XCTUnwrap(view.contigsExportInvocation(outputURL: Self.outputURL(in: root)))
        let failures = NvdExportFailureCalls()
        guard let begun = NvdResultViewController.beginNvdContigsExportOperation(
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
        try assertAEqualsC(runs, parityCase)
        try assertPredictedRecordChanges(runs, parityCase)
        return runs
    }

    /// A against C on the facts of 1.7, with each record path read relative to its side root. No file but the
    /// record differs, and the record's compared facts are equal.
    private func assertAEqualsC(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter { !$0.id.contains(sidecarName) }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payloadA = try Data(contentsOf: Self.outputURL(in: runs.a.root))
        XCTAssertEqual(payloadA, try Data(contentsOf: Self.outputURL(in: runs.c.root)), "the payload byte for byte")
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root), Self.inputs(of: c, under: runs.c.root), "inputs and digests")
        XCTAssertFalse(Self.inputs(of: c, under: runs.c.root).values.contains("no digest"), "every input has a digest")
        let metadataInput = parityCase == .shownRowsWithMetadataColumn ? ["/nvd-result/metadata/sample_metadata.tsv"] : []
        XCTAssertEqual(
            Self.inputs(of: c, under: runs.c.root).keys.sorted(),
            ["/nvd-result/hits.sqlite", "/nvd-result/manifest.json"] + metadataInput,
            "the database, the manifest and the metadata table a shown column reads, never the run folder (M4-2, M4-3)"
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
    /// leaf, the leaf drops the two keys that describe the outline, and its `explicit` part names the options the row
    /// passed. The record's argv is the row's command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let outputA = Self.outputURL(in: runs.a.root)
        let argvA = ["Lungfish.app", "export-nvd-contigs", "--output", outputA.path]
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, "lungfish app nvd contigs export")
        XCTAssertEqual(Set(a.options.resolvedDefaults.keys), Self.sharedResolvedKeys.union(Self.unappliedKeys))
        XCTAssertEqual(a.options.resolvedDefaults["groupingMode"]?.stringValue, "bySample")
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["format", "outputPath"])
        XCTAssertEqual(a.options.defaults, ["format": .string("tsv")])

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, NvdContigsExport.workflowName)
        XCTAssertEqual(c.options.defaults, [:])
        XCTAssertEqual(Set(c.options.resolvedDefaults.keys), Self.sharedResolvedKeys)
        switch parityCase {
        case .shownRowsWithMetadataColumn:
            XCTAssertEqual(c.options.explicit.keys.sorted(), ["metadataColumns", "outputPath", "samples", "searchText"])
        case .everySampleWithNoColumnShown:
            XCTAssertEqual(c.options.explicit.keys.sorted(), ["outputPath", "samples"])
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
