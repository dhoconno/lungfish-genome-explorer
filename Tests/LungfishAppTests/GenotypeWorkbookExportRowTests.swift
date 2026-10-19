// GenotypeWorkbookExportRowTests.swift - The Operations row of the genotype viewer's workbook export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row B1, ARCH-12.35-B1 conditions 2, 3, 6 and 8, ARCH ruling 1.5 rule 3.
// `GenotypeResultViewController.beginWorkbookExportOperation` begins an export row with no lock and a cancel
// callback, records the `genotype export-xlsx --snapshot` command the runner runs, which carries no `--format json`,
// and launches nothing when the row is refused. `runWorkbookExport` writes `capture.json` and `request.json` before
// `begin` and passes `--force` only when the output exists. GenotypeWorkbookExportCLIGUIParityReplayTests runs it.
// The view's export task runs it by default, and the coordinator publishes a cancel with no alert.

import AppKit
import XCTest
@testable import LungfishCLI
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class WorkbookExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class GenotypeWorkbookExportRowTests: XCTestCase {
    private let exportInvocation = GenotypeWorkbookExport.Invocation(
        captureURL: URL(fileURLWithPath: "/tmp/lane 12.35/Exports/.lungfish-export-inputs/A/capture.json"),
        requestURL: URL(fileURLWithPath: "/tmp/lane 12.35/Exports/.lungfish-export-inputs/A/request.json"),
        pythonURL: URL(fileURLWithPath: "/tmp/lane 12.35/envs/openpyxl/bin/python3"),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.35/Exports/Genotypes, reviewed.xlsx"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(GenotypeResultViewController.beginWorkbookExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        let outcome = await begun.task.value
        XCTAssertEqual(outcome, .completed(URL(fileURLWithPath: exportInvocation.output)), "a result row completes on exit 0")

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Genotype Workbook")
        XCTAssertEqual(item.initialDetail, "Writing Genotypes, reviewed.xlsx")

        XCTAssertEqual(try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item.cliCommand)), exportInvocation.arguments(),
            "the row records the arguments the runner runs")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: GenotypeExportXlsxSubcommand.self)
        XCTAssertEqual(command.snapshot, exportInvocation.capture)
        XCTAssertEqual(command.provenanceRequest, exportInvocation.request)
        XCTAssertEqual(command.python, exportInvocation.python)
        XCTAssertEqual(command.output, exportInvocation.output)
        XCTAssertNil(command.bundle)
        XCTAssertTrue(command.force)
    }

    /// Condition 8. When the export task throws `CancellationError`, which `runWorkbookExportToEnd` throws for a
    /// cancelled row, the coordinator publishes a failure that says no file was written and attaches no alert sheet.
    func testACancelledExportPublishesNoFileWrittenWithNoAlert() async throws {
        let root = try TestTempDirectory.make(prefix: "WorkbookExportCancelEvent")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // A window that was never ordered front attaches no alert sheet, so a missing sheet would prove nothing.
        window.orderFrontRegardless()
        defer { window.close() }
        controller.configure(result: GenotypeTestFixtures.makeResult(bundleURL: root, calls: [
            GenotypeTestFixtures.makeCall(sample: "AnimalA", genotype: "Mafa-A*001", reads: 9),
        ]))
        controller.excelSavePanelPresenter = { _, _, completion in completion(root.appendingPathComponent("report.xlsx")) }
        controller.viewportExportRunner = { _, _ in throw CancellationError() }
        var events: [String] = []
        let settled = expectation(description: "the export settled")
        controller.onExcelExportEvent = { event in
            switch event {
            case .started: events.append("started")
            case .succeeded: events.append("succeeded"); settled.fulfill()
            case .failed(let message): events.append(message); settled.fulfill()
            }
        }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(events, ["started", "The export was cancelled. No file was written."])
        XCTAssertNil(window.attachedSheet, "a cancel shows no alert")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = GenotypeResultViewController.beginWorkbookExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        XCTAssertEqual(try RouteParityHarness.arguments(ofLine: reporter.items.first?.cliCommand ?? ""), exportInvocation.arguments())
    }

    /// The coordinator's alert shows what the failure carries. A leaf that fails fails the run, and `onFailure` gets
    /// its message once (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = WorkbookExportFailureCalls()
        let begun = try XCTUnwrap(GenotypeResultViewController.beginWorkbookExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    /// Conditions 1 to 3 and 6. Before `begin` the helper writes the frozen capture with the service's encoder and the
    /// request whose argv is the row's command, and `--force` is passed only when the file the save panel returned
    /// exists.
    func testTheInputsAreWrittenBeforeBeginAndForceIsPassedOnlyOnReplace() async throws {
        let root = try TestTempDirectory.make(prefix: "genotype-workbook-row")
        defer { TestTempDirectory.cleanup(root) }
        let output = root.appendingPathComponent("report.xlsx")
        let snapshot = try GenotypeWorkbookExportCLIGUIParityReplayTests.snapshot(
            for: .oneCallWithThresholds, bundleURL: root.appendingPathComponent("run.lungfishgenotype", isDirectory: true)
        )

        let first = try await runAndParse(snapshot: snapshot, output: output)
        XCTAssertFalse(first.command.force, "a new file is not replaced")
        let captureURL = URL(fileURLWithPath: try XCTUnwrap(first.command.snapshot))
        let requestURL = URL(fileURLWithPath: try XCTUnwrap(first.command.provenanceRequest))
        XCTAssertEqual(captureURL.deletingLastPathComponent(), requestURL.deletingLastPathComponent())
        XCTAssertEqual(captureURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            ViewerExportSelection.inputsFolderName)
        let decoded = try GenotypeViewportExportService.decodedCapture(snapshot)
        XCTAssertEqual(try Data(contentsOf: captureURL), try GenotypeExcelExportService.replayEncoded(decoded),
            "the frozen capture, with the service's encoder")
        let request = try JSONDecoder().decode(GenotypeExcelExportService.ProvenanceRequest.self, from: Data(contentsOf: requestURL))
        XCTAssertEqual(request.workflowName, "genotype.export.excel")
        XCTAssertEqual(request.argv, [CLICommandIdentity.executableName] + first.arguments, "the request names the row's command")
        XCTAssertEqual(request.options["replacingExisting"], "false")
        XCTAssertEqual(request.options["matrixMinimumReads"], "5")
        XCTAssertEqual(request.runtimeContext["entryPoint"], "Inspector Export to Excel")

        try Data("workbook".utf8).write(to: output)
        let second = try await runAndParse(snapshot: snapshot, output: output)
        XCTAssertTrue(second.command.force, "the save panel's Replace replaces the file")
    }

    /// The positive control of the cancel test (X14, QA 1 and 4). The setup is the cancel test's, with an export task
    /// that throws a leaf failure, which the coordinator shows as an alert sheet on the controller's window. While this
    /// test passes, the cancel test's missing sheet is a measurement and not a harness that never shows an alert.
    func testAFailedExportShowsItsAlert() async throws {
        let root = try TestTempDirectory.make(prefix: "WorkbookExportFailureAlert")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // A window that was never ordered front attaches no alert sheet, so a missing sheet would prove nothing.
        window.orderFrontRegardless()
        defer { window.close() }
        controller.configure(result: GenotypeTestFixtures.makeResult(bundleURL: root, calls: [
            GenotypeTestFixtures.makeCall(sample: "AnimalA", genotype: "Mafa-A*001", reads: 9),
        ]))
        controller.excelSavePanelPresenter = { _, _, completion in completion(root.appendingPathComponent("report.xlsx")) }
        controller.viewportExportRunner = { _, _ in throw CLIViewerExportRunner.Failure(message: "The leaf failed.") }
        var events: [String] = []
        let settled = expectation(description: "the export settled")
        controller.onExcelExportEvent = { event in
            switch event {
            case .started: events.append("started")
            case .succeeded: events.append("succeeded"); settled.fulfill()
            case .failed(let message): events.append(message); settled.fulfill()
            }
        }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(events, ["started", "The leaf failed."])
        XCTAssertNotNil(window.attachedSheet, "a failed export shows its alert")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    /// `runWorkbookExportToEnd` is the seam's production default and the one place where a cancelled run becomes
    /// `CancellationError` and a failed run becomes the leaf's `Failure`. A leaf that exits 0 returns.
    func testTheExportTaskReturnsWhenTheLeafSucceeds() async throws {
        let root = try TestTempDirectory.make(prefix: "genotype-workbook-to-end-ok")
        defer { TestTempDirectory.cleanup(root) }
        let reporter = RecordingOperationReporter()
        try await GenotypeResultViewController.runWorkbookExportToEnd(
            snapshot: try exportSnapshot(in: root),
            outputURL: root.appendingPathComponent("report.xlsx"),
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        )
        XCTAssertEqual(reporter.items.count, 1, "the task began one row")
    }

    /// A leaf that exits 1 throws a `Failure` that carries a message, which the coordinator's alert shows.
    func testTheExportTaskThrowsTheLeafFailureWithAMessage() async throws {
        let root = try TestTempDirectory.make(prefix: "genotype-workbook-to-end-failed")
        defer { TestTempDirectory.cleanup(root) }
        do {
            try await GenotypeResultViewController.runWorkbookExportToEnd(
                snapshot: try exportSnapshot(in: root),
                outputURL: root.appendingPathComponent("report.xlsx"),
                pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
                runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
                reporter: RecordingOperationReporter()
            )
            XCTFail("a leaf that exits 1 fails the export task")
        } catch let failure as CLIViewerExportRunner.Failure {
            XCTAssertFalse(failure.message.isEmpty, "the alert shows the leaf's message")
        } catch {
            XCTFail("the export task throws the leaf's Failure, not \(error)")
        }
    }

    /// A runner cancelled before the call covers the run about to start (the runner's doc), so the task throws
    /// `CancellationError`, which the coordinator publishes with no alert.
    func testTheExportTaskThrowsCancellationErrorForACancelledRun() async throws {
        let root = try TestTempDirectory.make(prefix: "genotype-workbook-to-end-cancelled")
        defer { TestTempDirectory.cleanup(root) }
        let runner = CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true"))
        runner.cancel()
        do {
            try await GenotypeResultViewController.runWorkbookExportToEnd(
                snapshot: try exportSnapshot(in: root),
                outputURL: root.appendingPathComponent("report.xlsx"),
                pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
                runner: runner,
                reporter: RecordingOperationReporter()
            )
            XCTFail("a cancelled run throws CancellationError")
        } catch is CancellationError {
            // The coordinator reads this error as a cancel and shows no alert.
        } catch {
            XCTFail("a cancelled run throws CancellationError, not \(error)")
        }
    }

    private func exportSnapshot(in root: URL) throws -> GenotypeViewportExportSnapshot {
        try GenotypeWorkbookExportCLIGUIParityReplayTests.snapshot(
            for: .oneCallWithThresholds, bundleURL: root.appendingPathComponent("run.lungfishgenotype", isDirectory: true)
        )
    }

    private func runAndParse(
        snapshot: GenotypeViewportExportSnapshot, output: URL
    ) async throws -> (command: GenotypeExportXlsxSubcommand, arguments: [String]) {
        let reporter = RecordingOperationReporter()
        let begun = try await GenotypeResultViewController.runWorkbookExport(
            snapshot: snapshot,
            outputURL: output,
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in }
        let task = try XCTUnwrap(begun).task
        _ = await task.value
        let line = try XCTUnwrap(reporter.items.first?.cliCommand)
        return (try RecordedCLICommand.parse(line, as: GenotypeExportXlsxSubcommand.self), try RouteParityHarness.arguments(ofLine: line))
    }
}
