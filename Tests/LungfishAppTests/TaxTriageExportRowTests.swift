// TaxTriageExportRowTests.swift - The Operations rows of the TaxTriage organism matrix and batch report exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.32, ARCH ruling 1.5 rule 3. `TaxTriageResultViewController.beginTaxTriageOrganismMatrixExportOperation`
// and `beginTaxTriageBatchReportExportOperation` begin an export row with no lock and a cancel callback, record the
// `taxtriage export` command the runner runs, and launch nothing when the row is refused. A leaf that fails reaches
// the failure handler once, and an empty Sample Filter begins no row. TaxTriageExportCLIGUIParityReplayTests runs the
// commands.

import AppKit
import XCTest
@testable import LungfishCLI
@testable import LungfishTaxTriageUI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class TaxTriageRowFailureCalls {
    var messages: [String] = []
}

@MainActor
final class TaxTriageExportRowTests: XCTestCase {
    private let resultURL = URL(
        fileURLWithPath: "/tmp/lane 12.32/Project.lungfish/Analyses/taxtriage-batch", isDirectory: true
    )

    private var matrixInvocation: ViewerExportInvocation {
        TaxTriageOrganismMatrixExport.invocation(
            resultURL: resultURL,
            samples: ["sample-A", "sample B"],
            searchText: "beta virus",
            outputURL: URL(fileURLWithPath: "/tmp/lane 12.32/matrix, all.csv"),
            force: true
        )
    }

    private var reportInvocation: ViewerExportInvocation {
        TaxTriageBatchReportExport.invocation(
            resultURL: resultURL,
            samples: ["sample-A", "sample B"],
            searchText: nil,
            outputURL: URL(fileURLWithPath: "/tmp/lane 12.32/batch report.txt"),
            force: false
        )
    }

    private var resultsInvocation: ViewerExportInvocation {
        TaxTriageResultsExport.invocation(
            resultURL: resultURL,
            samples: ["sample-A", "sample B"],
            searchText: "beta virus",
            sortKeys: [ViewerExportSortKey(column: "tt_reads", ascending: false)],
            filters: ColumnFilterSet(
                filters: [ColumnFilter(columnId: "tt_reads", op: .greaterOrEqual, value: "10")],
                composition: .all
            ),
            metadataColumns: ["Group"],
            format: .tsv,
            outputURL: URL(fileURLWithPath: "/tmp/lane 12.32/results table.tsv"),
            force: false
        )
    }

    func testTheMatrixRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(TaxTriageResultViewController.beginTaxTriageOrganismMatrixExportOperation(
            invocation: matrixInvocation,
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
        XCTAssertEqual(item.title, "Export TaxTriage Organism Matrix")
        XCTAssertEqual(item.initialDetail, "Writing matrix, all.csv")

        let command = try RecordedCLICommand.parse(
            item.cliCommand, as: TaxTriageCommand.ExportOrganismMatrixSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), matrixInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample-A", "sample B"])
        XCTAssertEqual(command.search.text, "beta virus")
        XCTAssertEqual(command.output.path, "/tmp/lane 12.32/matrix, all.csv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testTheReportRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(TaxTriageResultViewController.beginTaxTriageBatchReportExportOperation(
            invocation: reportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export TaxTriage Batch Report")
        XCTAssertEqual(item.initialDetail, "Writing batch report.txt")

        let command = try RecordedCLICommand.parse(
            item.cliCommand, as: TaxTriageCommand.ExportBatchReportSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), reportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample-A", "sample B"])
        XCTAssertNil(command.search.text)
        XCTAssertFalse(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testTheResultsRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(TaxTriageResultViewController.beginTaxTriageResultsExportOperation(
            invocation: resultsInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export TaxTriage Results")
        XCTAssertEqual(item.initialDetail, "Writing results table.tsv")

        let command = try RecordedCLICommand.parse(
            item.cliCommand, as: TaxTriageCommand.ExportResultsSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), resultsInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample-A", "sample B"])
        XCTAssertEqual(command.sort.keys, [ViewerExportSortKey(column: "tt_reads", ascending: false)])
        XCTAssertEqual(command.metadataColumns.columns, ["Group"])
        XCTAssertEqual(command.format.format, .tsv)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    /// Both wrappers begin their row through `beginTaxTriageExportOperation`, which takes the row's title from its
    /// caller, so a third TaxTriage export begins its row the same way.
    func testTheSharedBodyTakesTheRowTitleFromItsCaller() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(TaxTriageResultViewController.beginTaxTriageExportOperation(
            title: "Export TaxTriage Results",
            invocation: reportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter,
            environmentAdditions: [:]
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "Export TaxTriage Results")
        XCTAssertEqual(item.operationType, .export)
        let command = try RecordedCLICommand.parse(
            item.cliCommand, as: TaxTriageCommand.ExportBatchReportSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), reportInvocation)
    }

    /// The leaf reads no `--sample` as every sample, so an empty Sample Filter must begin no row. Both Export actions
    /// return before the save panel.
    func testAnEmptySampleSelectionBeginsNoRow() async throws {
        let scratch = try TestTempDirectory.make(prefix: "taxtriage-export-row")
        defer { TestTempDirectory.cleanup(scratch) }
        try TaxTriageExportCLIGUIParityReplayTests.makeResult(scratch)
        let view = try await TaxTriageExportCLIGUIParityReplayTests.configuredView(scratch)
        let window = NSWindow(contentViewController: view)
        window.isReleasedWhenClosed = false
        XCTAssertEqual(view.selectedDatabaseSampleIds, ["sample-1", "sample-2"])
        let reportItem = NSMenuItem(title: "Export Batch Report", action: NSSelectorFromString("exportBatchReportAction:"), keyEquivalent: "")
        XCTAssertTrue(view.validateMenuItem(reportItem))
        view.samplePickerState.selectedSamples = []
        XCTAssertEqual(view.selectedDatabaseSampleIds, [])
        XCTAssertFalse(view.validateMenuItem(reportItem), "no ticked sample disables the report item")

        let rowsBefore = OperationCenter.shared.items.count
        for action in ["exportBatchMatrixAction:", "exportBatchReportAction:", "exportCSVAction:", "exportTSVAction:"] {
            view.perform(NSSelectorFromString(action), with: nil)
            XCTAssertNil(window.attachedSheet, "\(action) returned before the save panel")
        }
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore, "no row began and no leaf ran")
        XCTAssertNotNil(view.view.window)
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = TaxTriageResultViewController.beginTaxTriageOrganismMatrixExportOperation(
            invocation: matrixInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: TaxTriageCommand.ExportOrganismMatrixSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), matrixInvocation)

        let reportReporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let refusedReport = TaxTriageResultViewController.beginTaxTriageBatchReportExportOperation(
            invocation: reportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reportReporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }
        XCTAssertNil(refusedReport)
        XCTAssertEqual(reportReporter.items.map(\.state), [.refused])
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once. The Export action passes that to
    /// `ResultExportCoordinator.reportFailure` unchanged (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        for report in [false, true] {
            let calls = TaxTriageRowFailureCalls()
            let runner = CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false"))
            let reporter = RecordingOperationReporter()
            let begun: (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)?
            if report {
                begun = TaxTriageResultViewController.beginTaxTriageBatchReportExportOperation(
                    invocation: reportInvocation, runner: runner, reporter: reporter
                ) { failure in calls.messages.append(failure.message) }
            } else {
                begun = TaxTriageResultViewController.beginTaxTriageOrganismMatrixExportOperation(
                    invocation: matrixInvocation, runner: runner, reporter: reporter
                ) { failure in calls.messages.append(failure.message) }
            }
            let row = try XCTUnwrap(begun)
            let outcome = await row.task.value
            guard case .failed(let failure) = outcome else {
                return XCTFail("the leaf failed, the run ended \(outcome)")
            }
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertEqual(calls.messages, [failure.message], report ? "report" : "matrix")
        }
    }
}
