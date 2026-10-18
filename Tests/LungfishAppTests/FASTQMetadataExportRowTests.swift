// FASTQMetadataExportRowTests.swift - The Operations row of the FASTQ metadata drawer's export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34, ARCH ruling 1.5 rule 3. `FASTQMetadataDrawerView.beginFASTQSampleBarcodeExportOperation`
// begins an export row with no lock and a cancel callback, records the `fastq export sample-barcodes` command the
// runner runs, and launches nothing when the row is refused. `runSampleBarcodeExport` writes the selection file the
// command names beside the output. FASTQMetadataExportCLIGUIParityReplayTests runs the command.

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
private final class FASTQMetadataExportCalls {
    var messages: [String] = []
}

@MainActor
final class FASTQMetadataExportRowTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "fastq-metadata-export-row")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private let demuxInvocation = FASTQSampleBarcodeExport.invocation(
        bundleURL: URL(fileURLWithPath: "/tmp/lane 12.34/reads one.fastq"),
        tab: .demux,
        selectionURL: URL(fileURLWithPath: "/tmp/lane 12.34/.lungfish-export-inputs/ABC/selection.json"),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.34/pattern, all.csv"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(FASTQMetadataDrawerView.beginFASTQSampleBarcodeExportOperation(
            invocation: demuxInvocation,
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
        XCTAssertEqual(item.title, "Export Demultiplex Pattern")
        XCTAssertEqual(item.initialDetail, "Writing pattern, all.csv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqExportSampleBarcodesSubcommand.self)
        XCTAssertEqual(command.invocation(), demuxInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.bundlePath, "/tmp/lane 12.34/reads one.fastq")
        XCTAssertEqual(command.tab.tab, .demux)
        XCTAssertEqual(command.selection.path, "/tmp/lane 12.34/.lungfish-export-inputs/ABC/selection.json")
        XCTAssertEqual(command.output.path, "/tmp/lane 12.34/pattern, all.csv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testTheSamplesTabTitlesItsRowAsTheSampleMetadataExport() async throws {
        let reporter = RecordingOperationReporter()
        let invocation = FASTQSampleBarcodeExport.invocation(
            bundleURL: URL(fileURLWithPath: "/tmp/lane 12.34/reads.fastq"),
            tab: .samples,
            selectionURL: URL(fileURLWithPath: "/tmp/lane 12.34/selection.json"),
            outputURL: URL(fileURLWithPath: "/tmp/lane 12.34/sheet.csv"),
            force: false
        )
        let begun = try XCTUnwrap(FASTQMetadataDrawerView.beginFASTQSampleBarcodeExportOperation(
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value
        XCTAssertEqual(reporter.items.first?.title, "Export FASTQ Sample Metadata")
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: FastqExportSampleBarcodesSubcommand.self
        )
        XCTAssertEqual(command.tab.tab, .samples)
        XCTAssertFalse(command.output.force)
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = FASTQMetadataDrawerView.beginFASTQSampleBarcodeExportOperation(
            invocation: demuxInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: FastqExportSampleBarcodesSubcommand.self
        )
        XCTAssertEqual(command.invocation(), demuxInvocation)
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once.
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = FASTQMetadataExportCalls()
        let begun = try XCTUnwrap(FASTQMetadataDrawerView.beginFASTQSampleBarcodeExportOperation(
            invocation: demuxInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    /// The drawer's run writes the selection file in a new folder beside the output, names that file in the row's
    /// command, and asks for `--force` only when the chosen file exists (the panel confirmed the replace).
    func testTheRunWritesTheSelectionBesideTheOutputAndForcesOnlyAReplace() async throws {
        let source = scratch.appendingPathComponent("reads.fastq")
        try Data("@r\nA\n+\nI\n".utf8).write(to: source)
        let output = scratch.appendingPathComponent("sheet.csv")
        let selection = FASTQSampleBarcodeExport.selection(
            assignments: [FASTQSampleBarcodeAssignment(sampleID: "S1", sampleName: "Alpha", forwardBarcodeID: "BC01")],
            asymmetric: false
        )
        let drawer = FASTQMetadataDrawerView()
        let calls = FASTQMetadataExportCalls()

        let fresh = RecordingOperationReporter()
        let first = try XCTUnwrap(drawer.runSampleBarcodeExport(
            sourceURL: source, tab: .samples, selection: selection, outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")), reporter: fresh
        ) { calls.messages.append($0) })
        _ = await first.task.value
        let command = try RecordedCLICommand.parse(fresh.items.first?.cliCommand, as: FastqExportSampleBarcodesSubcommand.self)
        let selectionURL = URL(fileURLWithPath: command.selection.path)
        XCTAssertEqual(selectionURL.lastPathComponent, ViewerExportSelection.fileName)
        XCTAssertEqual(
            selectionURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            ViewerExportSelection.inputsFolderName
        )
        XCTAssertEqual(
            selectionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
            scratch.standardizedFileURL.path,
            "the folder sits beside the output"
        )
        XCTAssertEqual(try ViewerExportSelection.read(from: selectionURL), selection)
        XCTAssertFalse(command.output.force, "a new file needs no --force")
        XCTAssertEqual(calls.messages.count, 1, "/usr/bin/true wrote no complete line, so the run failed once")
        XCTAssertTrue(calls.messages.first?.hasPrefix("Export failed: ") ?? false, "\(calls.messages)")

        try Data("old".utf8).write(to: output)
        let replace = RecordingOperationReporter()
        let second = try XCTUnwrap(drawer.runSampleBarcodeExport(
            sourceURL: source, tab: .samples, selection: selection, outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")), reporter: replace
        ) { calls.messages.append($0) })
        _ = await second.task.value
        let replaced = try RecordedCLICommand.parse(replace.items.first?.cliCommand, as: FastqExportSampleBarcodesSubcommand.self)
        XCTAssertTrue(replaced.output.force, "an existing file is replaced with --force")
        XCTAssertNotEqual(replaced.selection.path, command.selection.path, "each export writes its own selection folder")
    }

    /// Today's words for a drawer with no durable source. No selection is written and no row begins.
    func testAMissingSourceReportsTodaysWordsAndBeginsNoRow() throws {
        let output = scratch.appendingPathComponent("sheet.csv")
        let reporter = RecordingOperationReporter()
        let calls = FASTQMetadataExportCalls()
        let selection = FASTQSampleBarcodeExport.selection(assignments: [], asymmetric: false)
        let drawer = FASTQMetadataDrawerView()
        let words = "Export failed: Cannot export FASTQ metadata because no durable source FASTQ or bundle is available for provenance."

        XCTAssertNil(drawer.runSampleBarcodeExport(
            sourceURL: nil, tab: .samples, selection: selection, outputURL: output, reporter: reporter
        ) { calls.messages.append($0) })
        XCTAssertNil(drawer.runSampleBarcodeExport(
            sourceURL: scratch.appendingPathComponent("gone.fastq"), tab: .demux, selection: selection,
            outputURL: output, reporter: reporter
        ) { calls.messages.append($0) })

        XCTAssertEqual(calls.messages, [words, words])
        XCTAssertEqual(reporter.items.count, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent(ViewerExportSelection.inputsFolderName).path
            ),
            "a refused run writes no selection file"
        )
    }
}
