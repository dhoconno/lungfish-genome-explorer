// NvdContigsExportRowTests.swift - The Operations row of the NVD contigs export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M4, ARCH ruling 1.5 rule 3. `NvdResultViewController.beginNvdContigsExportOperation` begins
// an export row with no lock and a cancel callback, records the `nvd export contigs` command the runner runs, and
// launches nothing when the row is refused. The view begins no row when no sample is picked (12.31 Fix 7).

import AppKit
import XCTest
@testable import LungfishCLI
@testable import LungfishNvdUI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class NvdContigsExportRowTests: XCTestCase {
    private let exportInvocation = NvdContigsExport.invocation(
        resultURL: URL(fileURLWithPath: "/tmp/lane 12.31/Project.lungfish/Analyses/nvd-result", isDirectory: true),
        state: ViewerTableExportState(
            samples: ["sample1", "sample 2"],
            searchText: "virus, all",
            metadataColumns: ["Cohort"]
        ),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.31/contigs, all.tsv"),
        force: true
    )

    override func setUp() {
        super.setUp()
        NvdResultViewController.testMetadataUserDefaultsOverride =
            makeTestDefaultsSuite(prefix: "NvdContigsExportRowTests").defaults
    }

    override func tearDown() {
        NvdResultViewController.testMetadataUserDefaultsOverride = nil
        super.tearDown()
    }

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(NvdResultViewController.beginNvdContigsExportOperation(
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
        XCTAssertEqual(item.title, "Export NVD Contigs")
        XCTAssertEqual(item.initialDetail, "Writing contigs, all.tsv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: NvdCommand.ExportContigsSubcommand.self)
        XCTAssertEqual(try command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample1", "sample 2"])
        XCTAssertEqual(command.search.text, "virus, all")
        XCTAssertEqual(command.output.path, "/tmp/lane 12.31/contigs, all.tsv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    /// Review 12.31-M3a Fix 7 on NVD. The leaf reads no `--sample` as every sample, so an empty picker begins no row,
    /// and the Export action returns before the save panel.
    func testAnEmptySampleSelectionBeginsNoRow() throws {
        let root = try TestTempDirectory.make(prefix: "nvd-export-row")
        defer { TestTempDirectory.cleanup(root) }
        try NvdExportCLIGUIParityReplayTests.makeResult(root)
        let view = try NvdExportCLIGUIParityReplayTests.configuredView(root, .everySampleWithNoColumnShown)
        let window = NSWindow(contentViewController: view)
        window.isReleasedWhenClosed = false
        view.samplePickerState.selectedSamples = []
        view.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertEqual(view.selectedSamples, [])
        let rowsBefore = OperationCenter.shared.items.count
        view.exportResults()
        XCTAssertNil(window.attachedSheet, "the export returns before the save panel")
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore, "no row began and no leaf ran")
        XCTAssertNotNil(view.view.window)
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = NvdResultViewController.beginNvdContigsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: NvdCommand.ExportContigsSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), exportInvocation)
    }

    /// A leaf that fails fails the row and reaches `onFailure` once, which shows today's alert.
    func testAFailedLeafReachesTheFailureHandler() async throws {
        let reporter = RecordingOperationReporter()
        let failures = NvdContigsExportFailures()
        let begun = try XCTUnwrap(NvdResultViewController.beginNvdContigsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { failure in failures.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, \(outcome)") }
        XCTAssertEqual(failures.messages, [failure.message])
    }
}

@MainActor
private final class NvdContigsExportFailures {
    var messages: [String] = []
}
