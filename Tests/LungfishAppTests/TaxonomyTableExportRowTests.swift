// TaxonomyTableExportRowTests.swift - The Operations row of the Kraken2 taxonomy table export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.33, ARCH ruling 1.5 rule 3 and the ruling on F1 (C5).
// `TaxonomyViewController.beginTaxonomyTableExportOperation` begins an export row with no lock and a cancel
// callback, records the `kraken2 export table` command the runner runs, and launches nothing when the row is
// refused. The view's invocation names the file the shown tree came from, the picked samples and the metadata
// columns shown. Kraken2TableExportCLIGUIParityReplayTests runs the command.

import AppKit
import SQLite3
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
@testable import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class TaxonomyFailureCalls {
    var messages: [String] = []
}

@MainActor
final class TaxonomyTableExportRowTests: XCTestCase {
    private var scratch: URL!

    private let exportInvocation = Kraken2TaxonomyTableExport.invocation(
        sourceURL: URL(fileURLWithPath: "/tmp/lane 12.33/Project.lungfish/Analyses/kraken2-batch/kraken2.sqlite"),
        samples: ["sample-A", "sample B"],
        metadataColumns: ["Group"],
        format: .csv,
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.33/taxonomy, all.csv"),
        force: true
    )

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "taxonomy-table-row")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(TaxonomyViewController.beginTaxonomyTableExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Taxonomy Table")
        XCTAssertEqual(item.initialDetail, "Writing taxonomy, all.csv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: Kraken2Command.ExportTableSubcommand.self)
        XCTAssertEqual(try command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample-A", "sample B"])
        XCTAssertEqual(command.metadataColumns.columns, ["Group"])
        XCTAssertEqual(command.output.path, "/tmp/lane 12.33/taxonomy, all.csv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    /// The leaf reads no `--sample` as every sample, so an empty picker must begin no row. It clears the tree, and
    /// the Export action returns before the save panel.
    func testAnEmptySampleSelectionBeginsNoRow() throws {
        let shown = try makeDatabaseView()
        let window = NSWindow(contentViewController: shown.view)
        window.isReleasedWhenClosed = false
        XCTAssertEqual(shown.view.taxonomyExportSource()?.samples, ["sample-A", "sample-B"])

        shown.view.samplePickerState.selectedSamples = []
        shown.view.testApplyBatchSampleFilter()
        XCTAssertNil(shown.view.tree)
        XCTAssertNil(shown.view.taxonomyExportSource())
        XCTAssertNil(shown.view.taxonomyExportInvocation(format: .tsv, outputURL: scratch.appendingPathComponent("none.tsv")))
        let rowsBefore = OperationCenter.shared.items.count
        shown.view.perform(NSSelectorFromString("exportTSVAction:"), with: shown.view)
        XCTAssertNil(window.attachedSheet, "the action returned before the save panel")
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore, "no row began and no leaf ran")
    }

    /// The view names the database the tree came from, the picked samples and the column shown, and a replaced file
    /// takes `--force`.
    func testTheViewsInvocationNamesTheDatabaseTheSamplesAndTheColumnsShown() throws {
        let shown = try makeDatabaseView()
        shown.view.samplePickerState.selectedSamples = ["sample-B"]
        shown.view.testApplyBatchSampleFilter()
        let outputURL = scratch.appendingPathComponent("taxonomy.tsv")
        let fresh = try XCTUnwrap(shown.view.taxonomyExportInvocation(format: .tsv, outputURL: outputURL))
        XCTAssertEqual(
            fresh,
            Kraken2TaxonomyTableExport.invocation(
                sourceURL: shown.folder.appendingPathComponent("kraken2.sqlite"),
                samples: ["sample-B"],
                metadataColumns: ["Group"],
                format: .tsv,
                outputURL: outputURL,
                force: false
            )
        )
        try Data("old".utf8).write(to: outputURL)
        let replacing = try XCTUnwrap(shown.view.taxonomyExportInvocation(format: .csv, outputURL: outputURL))
        XCTAssertTrue(replacing.force)
        XCTAssertEqual(replacing.outputFormat, "csv")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = TaxonomyViewController.beginTaxonomyTableExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: Kraken2Command.ExportTableSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), exportInvocation)
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once. `exportDelimited` passes that to
    /// `ResultExportCoordinator.reportFailure` unchanged (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = TaxonomyFailureCalls()
        let begun = try XCTUnwrap(TaxonomyViewController.beginTaxonomyTableExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    /// Phase 2.13 lane 13.35, BIO-R1 F9 and item 11. The sidebar shows a stale database whose reports are gone, so
    /// its Export reaches the leaf. The leaf refuses it before it writes, and the failure handler gets the leaf's
    /// message, which the existing failure alert shows.
    func testExportOfAShownStaleDatabaseEndsInTheLeafsRefusal() async throws {
        let shown = try makeDatabaseView()
        await shown.view.sampleMetadataCacheRefresh?.value
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(shown.folder.appendingPathComponent("kraken2.sqlite").path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle, "DELETE FROM metadata WHERE key = '\(Kraken2Database.formatVersionMetadataKey)'", nil, nil, nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        let outputURL = scratch.appendingPathComponent("stale.tsv")
        let invocation = try XCTUnwrap(shown.view.taxonomyExportInvocation(format: .tsv, outputURL: outputURL))
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(
                buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            ),
            "No lungfish-cli beside the test products and none named by LUNGFISH_CLI_PATH"
        )
        let calls = TaxonomyFailureCalls()
        let begun = try XCTUnwrap(TaxonomyViewController.beginTaxonomyTableExportOperation(
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: cli),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value

        guard case .failed(let failure) = outcome else {
            return XCTFail("the leaf refuses a stale database, the run ended \(outcome)")
        }
        XCTAssertTrue(
            failure.message.contains("Its reports are gone, so it cannot be rebuilt or exported."), failure.message
        )
        XCTAssertEqual(calls.messages, [failure.message])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    // MARK: - Fixture

    /// A folder with a Kraken2 database of two samples and a sample metadata table that gives them different groups,
    /// shown as the sidebar shows it, with the `Group` column visible.
    private func makeDatabaseView() throws -> (view: TaxonomyViewController, folder: URL) {
        let folder = scratch.appendingPathComponent("kraken2-batch", isDirectory: true)
        let metadata = folder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var rows: [Kraken2ClassificationRow] = []
        for (sample, name, reads) in [("sample-A", "Virus A", 40), ("sample-B", "Virus B", 20)] {
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                readsDirect: 0, readsClade: reads, percentage: 100, parentTaxId: nil, depth: 0
            ))
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: name, taxId: reads, rank: "S", rankDisplayName: "Species",
                readsDirect: reads, readsClade: reads, percentage: 100, parentTaxId: 1, depth: 1
            ))
        }
        let database = try Kraken2Database.create(
            at: folder.appendingPathComponent("kraken2.sqlite"),
            rows: rows,
            metadata: ["total_reads_sample-A": "40", "total_reads_sample-B": "20"]
        )
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        let view = TaxonomyViewController()
        isolateLayouts(view)
        _ = view.view
        view.configureFromDatabase(database)
        view.applySampleMetadata(SampleMetadataStore.load(from: folder, knownSampleIds: ["sample-A", "sample-B"]))
        view.testTableView.metadataColumns.persistenceKey = nil
        view.testTableView.metadataColumns.visibleColumns = ["Group"]
        return (view, folder)
    }
}
