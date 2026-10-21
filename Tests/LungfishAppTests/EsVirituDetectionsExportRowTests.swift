// EsVirituDetectionsExportRowTests.swift - The Operations row of the EsViritu detections export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M3, ARCH ruling 1.5 rule 3. `EsVirituResultViewController.beginEsVirituDetectionsExportOperation`
// begins an export row with no lock and a cancel callback, records the `esviritu export detections` command the
// runner runs, and launches nothing when the row is refused. EsVirituExportCLIGUIParityReplayTests runs the command.

import AppKit
import XCTest
@testable import LungfishCLI
@testable import LungfishEsVirituUI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
private final class FailureCalls {
    var messages: [String] = []
}

@MainActor
final class EsVirituDetectionsExportRowTests: XCTestCase {
    private let exportInvocation = EsVirituDetectionExport.invocation(
        resultURL: URL(fileURLWithPath: "/tmp/lane 12.31/Project.lungfish/Analyses/esviritu-batch", isDirectory: true),
        samples: ["sample-A", "sample B"],
        metadataColumns: ["Group"],
        format: .csv,
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.31/detections, all.csv"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(EsVirituResultViewController.beginEsVirituDetectionsExportOperation(
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
        XCTAssertEqual(item.title, "Export EsViritu Detections")
        XCTAssertEqual(item.initialDetail, "Writing detections, all.csv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: EsVirituCommand.ExportDetectionsSubcommand.self)
        XCTAssertEqual(try command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample-A", "sample B"])
        XCTAssertEqual(command.output.path, "/tmp/lane 12.31/detections, all.csv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    /// Review 12.31-M3a Fix 7. The leaf reads no `--sample` as every sample, so an empty picker must begin no row. It
    /// clears the result, and the Export action returns before the save panel.
    func testAnEmptySampleSelectionBeginsNoRow() {
        let view = EsVirituResultViewController()
        isolateLayouts(view)
        let window = NSWindow(contentViewController: view)
        window.isReleasedWhenClosed = false
        view.isBatchMode = true
        view.samplePickerState = ClassifierSamplePickerState(allSamples: ["sample-A", "sample-B"])
        view.samplePickerState.selectedSamples = []
        view.applyBatchSampleFilter()
        XCTAssertNil(view.esVirituResult)
        let rowsBefore = OperationCenter.shared.items.count
        view.perform(NSSelectorFromString("exportTSVAction:"), with: nil)
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore, "no row began and no leaf ran")
        XCTAssertNotNil(view.view.window)
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = EsVirituResultViewController.beginEsVirituDetectionsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: EsVirituCommand.ExportDetectionsSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), exportInvocation)
    }

    /// The words of the deleted `testFailureAlertWords`. A leaf that fails fails the run, and `onFailure` gets its
    /// message once. `exportDelimited` passes that to `ResultExportCoordinator.reportFailure` unchanged (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = FailureCalls()
        let begun = try XCTUnwrap(EsVirituResultViewController.beginEsVirituDetectionsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }
}
