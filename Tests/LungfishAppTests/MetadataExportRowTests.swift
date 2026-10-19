// MetadataExportRowTests.swift - The Operations row of the folder and project metadata CSV export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, ARCH ruling 1.5 rule 3, row B12. `AppDelegate.beginMetadataExportOperation` begins an export
// row with no lock and a cancel callback, records the `metadata export` command the runner runs, and launches nothing
// when the row is refused. `AppDelegate.runMetadataExport` writes the selection file the command names beside the
// output. MetadataExportCLIGUIParityReplayTests runs the command.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class MetadataExportCalls {
    var messages: [String] = []
}

@MainActor
final class MetadataExportRowTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "metadata-export-row")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private let exportInvocation = FolderMetadataExport.invocation(
        folderURL: URL(fileURLWithPath: "/tmp/lane 12.38/Run Folder"),
        selectionURL: URL(fileURLWithPath: "/tmp/lane 12.38/.lungfish-export-inputs/ABC/selection.json"),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.38/samples, all.csv"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AppDelegate.beginMetadataExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        let outcome = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Sample Metadata")
        XCTAssertEqual(item.initialDetail, "Writing samples, all.csv")
        guard case .completed = outcome else { return XCTFail("a leaf that exits 0 completes, the run ended \(outcome)") }

        let command = try RecordedCLICommand.parse(item.cliCommand, as: MetadataExportSubcommand.self)
        XCTAssertEqual(command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.folderPath, "/tmp/lane 12.38/Run Folder")
        XCTAssertEqual(command.selectionPath, "/tmp/lane 12.38/.lungfish-export-inputs/ABC/selection.json")
        XCTAssertEqual(command.outputPath, "/tmp/lane 12.38/samples, all.csv")
        XCTAssertTrue(command.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .text, "the row's contract is not events, so it adds no --format json")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = AppDelegate.beginMetadataExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: MetadataExportSubcommand.self)
        XCTAssertEqual(command.invocation(), exportInvocation)
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once.
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = MetadataExportCalls()
        let begun = try XCTUnwrap(AppDelegate.beginMetadataExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    /// The run writes the selection file in a new folder beside the output, names that file in the row's command, and
    /// asks for `--force` only when the chosen file exists (the panel confirmed the replace).
    func testTheRunWritesTheSelectionBesideTheOutputAndForcesOnlyAReplace() async throws {
        let folder = scratch.appendingPathComponent("Run", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = scratch.appendingPathComponent("samples.csv")
        var sample = FASTQSampleMetadata(sampleName: "Alpha")
        sample.host = "human"
        sample.customFields = ["Batch": "b1"]
        let reporter = RecordingOperationReporter()
        let calls = MetadataExportCalls()
        let runner = CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true"))

        let first = try XCTUnwrap(AppDelegate.runMetadataExport(
            folderURL: folder, samples: [sample], outputURL: output, runner: runner, reporter: reporter
        ) { calls.messages.append($0) })
        _ = await first.task.value
        let firstCommand = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: MetadataExportSubcommand.self)
        let selectionURL = URL(fileURLWithPath: try XCTUnwrap(firstCommand.selectionPath))
        XCTAssertEqual(selectionURL.lastPathComponent, ViewerExportSelection.fileName)
        XCTAssertEqual(
            selectionURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            ViewerExportSelection.inputsFolderName
        )
        let selection = try ViewerExportSelection.read(from: selectionURL)
        XCTAssertEqual(FolderMetadataExport.samples(in: selection), [sample], "the selection holds the sample as it stands")
        XCTAssertFalse(firstCommand.force, "the file did not exist")
        XCTAssertEqual(firstCommand.outputPath, output.standardizedFileURL.path)
        XCTAssertEqual(calls.messages, [])

        try "old".write(to: output, atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(AppDelegate.runMetadataExport(
            folderURL: folder, samples: [sample], outputURL: output, runner: runner, reporter: reporter
        ) { calls.messages.append($0) })
        _ = await second.task.value
        let secondCommand = try RecordedCLICommand.parse(reporter.items.last?.cliCommand, as: MetadataExportSubcommand.self)
        XCTAssertTrue(secondCommand.force, "the panel confirmed the replace of the existing file")
        XCTAssertNotEqual(secondCommand.selectionPath, firstCommand.selectionPath, "each export has its own selection folder")
    }

    func testTheFailureAlertKeepsTodaysWords() {
        XCTAssertEqual(
            AppDelegate.metadataExportFailureAlert("Output file already exists"),
            AppDelegate.MetadataExportAlert(title: "Export Failed", message: "Output file already exists")
        )
    }
}
