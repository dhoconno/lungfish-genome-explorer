// SequenceFASTAExportRowTests.swift - The Operations row of the sequence view's FASTA export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M3, ARCH ruling 1.5 rule 3, row A12. `SequenceViewerView.runSequenceFASTAExport` stages the
// sequence as a one-record FASTA file beside the output, begins the export row that the FASTA records export begins,
// and records the `extract sequence` command the runner runs, which names the staged file, the sequence and the
// 80-column width. It removes the staged file when nothing was published and begins nothing when the row is refused.
// SequenceFASTAExportCLIGUIParityReplayTests runs the command.

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
private final class SequenceFASTAExportCalls {
    var messages: [String] = []
}

@MainActor
final class SequenceFASTAExportRowTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "sequence-fasta-export-row")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private func inputFolders(besides output: URL) throws -> [String] {
        let root = output.deletingLastPathComponent().appendingPathComponent(ViewerExportSelection.inputsFolderName)
        return (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    /// The run stages the sequence as the data (the bases on one line) beside the output, and the row's command names
    /// the staged file, the sequence by its name and the width. The chosen file exists, so the command asks for
    /// `--force` and the staged file stays after the leaf (a stand-in that fails) left the old output.
    func testTheRunStagesOneSequenceAndRecordsTheCommandItRuns() async throws {
        let output = scratch.appendingPathComponent("selected.fasta")
        try Data("old".utf8).write(to: output)
        let reporter = RecordingOperationReporter()
        let calls = SequenceFASTAExportCalls()
        let begun = try unwrapStarted(await SequenceViewerView.runSequenceFASTAExport(
            name: "chr1", description: "visible track", bases: "ACGTACGT", outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")), reporter: reporter
        ) { calls.messages.append($0) })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export FASTA")
        XCTAssertEqual(item.initialDetail, "Writing selected.fasta")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.sequenceNames, ["chr1"])
        XCTAssertEqual(command.lineWidthArgument, 80)
        XCTAssertNil(command.selection, "one sequence is named, so there is no selection file")
        XCTAssertNil(command.regionArgument)
        XCTAssertTrue(command.force, "an existing file is replaced with --force")
        XCTAssertEqual(command.output, output.standardizedFileURL.path)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")

        let stagedURL = URL(fileURLWithPath: command.input)
        let folder = stagedURL.deletingLastPathComponent()
        XCTAssertEqual(stagedURL.lastPathComponent, FASTARecordsExport.stagedSequenceFileName)
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, ViewerExportSelection.inputsFolderName)
        XCTAssertEqual(
            folder.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
            scratch.standardizedFileURL.path,
            "the folder sits beside the output"
        )
        XCTAssertEqual(try String(contentsOf: stagedURL, encoding: .utf8), ">chr1 visible track\nACGTACGT\n", "the data and not the wrapping")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["sequence.fa"], "no selection file")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "old", "the app writes no byte of the output")
    }

    /// A failed leaf that published nothing removes the staged file, and a new file needs no `--force`.
    func testAFailedRunThatPublishedNothingRemovesTheStagedFile() async throws {
        let output = scratch.appendingPathComponent("new.fasta")
        let reporter = RecordingOperationReporter()
        let calls = SequenceFASTAExportCalls()
        let begun = try unwrapStarted(await SequenceViewerView.runSequenceFASTAExport(
            name: "s", description: nil, bases: "ACGT", outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")), reporter: reporter
        ) { calls.messages.append($0) })
        _ = await begun.task.value
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertFalse(command.force, "a new file needs no --force")
        XCTAssertEqual(calls.messages.count, 1, "/usr/bin/true wrote no complete line, so the run failed once")
        XCTAssertEqual(try inputFolders(besides: output), [], "a failed run that published nothing removes its inputs")
    }

    /// A refused row starts nothing, leaves no staged file and shows no failure of its own.
    func testARefusedRowStartsNothingAndLeavesNoStagedFile() async throws {
        let output = scratch.appendingPathComponent("refused.fasta")
        let calls = SequenceFASTAExportCalls()
        let refusing = RecordingOperationReporter(lockHeldBy: "Another export")
        let refused = await SequenceViewerView.runSequenceFASTAExport(
            name: "s", description: nil, bases: "ACGT", outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")), reporter: refusing
        ) { calls.messages.append($0) }
        XCTAssertNil(refused)
        XCTAssertEqual(refusing.items.map(\.state), [.refused])
        XCTAssertEqual(try inputFolders(besides: output), [], "a refused row removes the file it staged")
        XCTAssertEqual(calls.messages, [])
    }

    /// A name that holds a space cannot be told from its description by the first word, so the command names the
    /// whole header line, and a name without one is given as it is.
    func testANameWithASpaceIsGivenAsTheWholeHeaderLine() async throws {
        let output = scratch.appendingPathComponent("spaced.fasta")
        try Data("old".utf8).write(to: output)
        let reporter = RecordingOperationReporter()
        let begun = try unwrapStarted(await SequenceViewerView.runSequenceFASTAExport(
            name: "my seq", description: "circular", bases: "GATTACA", outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")), reporter: reporter
        ) { _ in })
        _ = await begun.task.value
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: ExtractSequenceSubcommand.self)
        XCTAssertEqual(command.sequenceNames, ["my seq circular"])
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: command.input), encoding: .utf8), ">my seq circular\nGATTACA\n")
    }
}
