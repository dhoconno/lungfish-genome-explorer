// NaoMgsTableExportRowTests.swift - The Operations row of the NAO-MGS table export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M4, ARCH ruling 1.5 rule 3. `NaoMgsResultViewController.beginNaoMgsTableExportOperation`
// begins an export row with no lock and a cancel callback, records the `nao-mgs export table` command the runner
// runs, and launches nothing when the row is refused.

import AppKit
import XCTest
@testable import LungfishCLI
@testable import LungfishNaoMgsUI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class NaoMgsTableExportRowTests: XCTestCase {
    private let exportInvocation = NaoMgsSummaryExport.invocation(
        resultURL: URL(fileURLWithPath: "/tmp/lane 12.31/Project.lungfish/Analyses/naomgs-result", isDirectory: true),
        state: ViewerTableExportState(
            samples: ["sample-A", "sample B"],
            searchText: "virus, all",
            sortKeys: [ViewerExportSortKey(column: "hits", ascending: true)],
            filters: ColumnFilterSet(
                filters: [ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "10")],
                composition: .all
            ),
            metadataColumns: ["Cohort"]
        ),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.31/summary, all.tsv"),
        force: true
    )

    override func setUpWithError() throws {
        NaoMgsResultViewController.testMetadataUserDefaultsOverride =
            makeTestDefaultsSuite(prefix: "NaoMgsTableExportRowTests").defaults
    }

    override func tearDownWithError() throws {
        NaoMgsResultViewController.testMetadataUserDefaultsOverride = nil
    }

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(NaoMgsResultViewController.beginNaoMgsTableExportOperation(
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
        XCTAssertEqual(item.title, "Export NAO-MGS Summary")
        XCTAssertEqual(item.initialDetail, "Writing summary, all.tsv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: NaoMgsCommand.ExportTableSubcommand.self)
        XCTAssertEqual(try command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample-A", "sample B"])
        XCTAssertEqual(command.search.text, "virus, all")
        XCTAssertEqual(command.output.path, "/tmp/lane 12.31/summary, all.tsv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = NaoMgsResultViewController.beginNaoMgsTableExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: NaoMgsCommand.ExportTableSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), exportInvocation)
    }

    /// A leaf that fails fails the row and reaches `onFailure` once, which shows today's alert.
    func testAFailedLeafReachesTheFailureHandler() async throws {
        let reporter = RecordingOperationReporter()
        let failures = NaoMgsTableExportFailures()
        let begun = try XCTUnwrap(NaoMgsResultViewController.beginNaoMgsTableExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { failure in failures.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, \(outcome)") }
        XCTAssertEqual(failures.messages, [failure.message])
    }

    /// Review 12.31-M4 Fix 1. A sort on a metadata column orders no row, so the invocation names no sort key.
    func testASortOnAMetadataColumnIsNotNamedInTheInvocation() throws {
        let root = try TestTempDirectory.make(prefix: "naomgs-export-row")
        defer { TestTempDirectory.cleanup(root) }
        try NaoMgsExportCLIGUIParityReplayTests.makeResult(root)
        let view = try NaoMgsExportCLIGUIParityReplayTests.configuredView(root, .shownRowsWithMetadataColumn)
        let output = root.appendingPathComponent("rows.tsv")
        view.testTaxonomyTableView.sortDescriptors = [NSSortDescriptor(key: "metadata_Cohort", ascending: true)]
        XCTAssertEqual(try XCTUnwrap(view.tableExportInvocation(outputURL: output)).state.sortKeys, [])
        view.testTaxonomyTableView.sortDescriptors = [NSSortDescriptor(key: "hits", ascending: false)]
        XCTAssertEqual(
            try XCTUnwrap(view.tableExportInvocation(outputURL: output)).state.sortKeys,
            [ViewerExportSortKey(column: "hits", ascending: false)]
        )
    }
}

@MainActor
private final class NaoMgsTableExportFailures {
    var messages: [String] = []
}
