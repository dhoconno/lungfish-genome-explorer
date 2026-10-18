// FASTARecordsExportRowTests.swift - The Operations row of the viewers' FASTA records export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M3, ARCH ruling 1.5 rule 3. `ViewerViewController.beginFASTARecordsExportOperation` begins an
// export row with no lock and a cancel callback, records the `extract sequence` command the runner runs, and launches
// nothing when the row is refused. `runFASTARecordsExport` stages the records and the selection file the command names
// beside the output, and removes them when nothing was published.
// FASTARecordsExportCLIGUIParityReplayTests runs the command.

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

/// `XCTUnwrap` takes an autoclosure that cannot await, so a test awaits the run as an argument and unwraps it here.
func unwrapStarted<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

@MainActor
private final class FASTARecordsExportCalls {
    var messages: [String] = []
}

@MainActor
final class FASTARecordsExportRowTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "fasta-records-export-row")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private let exportInvocation = FASTARecordsExport.invocation(
        sourceURL: URL(fileURLWithPath: "/tmp/lane 12.34/.lungfish-export-inputs/ABC/records.fa"),
        selectionURL: URL(fileURLWithPath: "/tmp/lane 12.34/.lungfish-export-inputs/ABC/selection.json"),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.34/selected, all.fa"),
        force: true
    )

    private static let records = [">a one\nACGT\n", ">b\nTT\n"]

    private func inputFolders(besides output: URL) throws -> [String] {
        let root = output.deletingLastPathComponent().appendingPathComponent(ViewerExportSelection.inputsFolderName)
        return (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(ViewerViewController.beginFASTARecordsExportOperation(
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
        XCTAssertEqual(item.title, "Export FASTA")
        XCTAssertEqual(item.initialDetail, "Writing selected, all.fa")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.recordsInvocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.input, "/tmp/lane 12.34/.lungfish-export-inputs/ABC/records.fa")
        XCTAssertNil(command.regionArgument)
        XCTAssertEqual(command.selection, "/tmp/lane 12.34/.lungfish-export-inputs/ABC/selection.json")
        XCTAssertEqual(command.output, "/tmp/lane 12.34/selected, all.fa")
        XCTAssertTrue(command.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = ViewerViewController.beginFASTARecordsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.recordsInvocation(), exportInvocation)
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once.
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = FASTARecordsExportCalls()
        let begun = try XCTUnwrap(ViewerViewController.beginFASTARecordsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    /// The run stages the records as given and the headers as the selection in one new folder beside the output,
    /// names both in the row's command, and asks for `--force` only when the chosen file exists. A failed leaf that
    /// published nothing removes the folder, and one that failed over an existing file keeps it.
    func testTheRunStagesTheRecordsAndTheSelectionBesideTheOutput() async throws {
        let output = scratch.appendingPathComponent("selected.fa")
        let calls = FASTARecordsExportCalls()

        let fresh = RecordingOperationReporter()
        let first = try unwrapStarted(await ViewerViewController.runFASTARecordsExport(
            records: Self.records, outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")), reporter: fresh
        ) { calls.messages.append($0) })
        _ = await first.task.value
        let command = try RecordedCLICommand.parse(fresh.items.first?.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertFalse(command.force, "a new file needs no --force")
        XCTAssertEqual(calls.messages.count, 1, "/usr/bin/true wrote no complete line, so the run failed once")
        XCTAssertEqual(try inputFolders(besides: output), [], "a failed run that published nothing removes its inputs")

        try Data("old".utf8).write(to: output)
        let replace = RecordingOperationReporter()
        let second = try unwrapStarted(await ViewerViewController.runFASTARecordsExport(
            records: Self.records, outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")), reporter: replace
        ) { calls.messages.append($0) })
        _ = await second.task.value
        let replaced = try RecordedCLICommand.parse(replace.items.first?.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertTrue(replaced.force, "an existing file is replaced with --force")

        let stagedURL = URL(fileURLWithPath: replaced.input)
        let selectionURL = URL(fileURLWithPath: try XCTUnwrap(replaced.selection))
        XCTAssertEqual(stagedURL.lastPathComponent, FASTARecordsExport.stagedFileName)
        XCTAssertEqual(selectionURL.lastPathComponent, ViewerExportSelection.fileName)
        XCTAssertEqual(stagedURL.deletingLastPathComponent(), selectionURL.deletingLastPathComponent(), "one folder holds both")
        XCTAssertEqual(
            stagedURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            ViewerExportSelection.inputsFolderName
        )
        XCTAssertEqual(
            stagedURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
            scratch.standardizedFileURL.path,
            "the folder sits beside the output"
        )
        XCTAssertEqual(try String(contentsOf: stagedURL, encoding: .utf8), Self.records.joined(), "the records as given")
        XCTAssertEqual(try ViewerExportSelection.read(from: selectionURL).identities, ["a one", "b"])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "old", "the app writes no byte of the output")
        XCTAssertNotEqual(replaced.input, command.input, "each export stages its own folder")
    }

    /// Records with no header, and a refused row, start nothing and leave no staged file.
    func testNothingStartsForRecordsWithNoHeaderOrARefusedRow() async throws {
        let output = scratch.appendingPathComponent("none.fa")
        let calls = FASTARecordsExportCalls()
        let reporter = RecordingOperationReporter()
        let headerless = await ViewerViewController.runFASTARecordsExport(
            records: ["ACGT\n"], outputURL: output, reporter: reporter
        ) { calls.messages.append($0) }
        let empty = await ViewerViewController.runFASTARecordsExport(
            records: [], outputURL: output, reporter: reporter
        ) { calls.messages.append($0) }
        XCTAssertNil(headerless)
        XCTAssertNil(empty)
        XCTAssertEqual(calls.messages, [
            "The records hold no FASTA header, so there is nothing to export.",
            "The records hold no FASTA header, so there is nothing to export.",
        ])
        XCTAssertEqual(reporter.items.count, 0)
        XCTAssertEqual(try inputFolders(besides: output), [])

        let refusing = RecordingOperationReporter(lockHeldBy: "Another export")
        let refused = await ViewerViewController.runFASTARecordsExport(
            records: Self.records, outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")), reporter: refusing
        ) { calls.messages.append($0) }
        XCTAssertNil(refused)
        XCTAssertEqual(refusing.items.map(\.state), [.refused])
        XCTAssertEqual(try inputFolders(besides: output), [], "a refused row removes the files it staged")
        XCTAssertEqual(calls.messages.count, 2, "a refused row shows no failure of its own")
    }
}
