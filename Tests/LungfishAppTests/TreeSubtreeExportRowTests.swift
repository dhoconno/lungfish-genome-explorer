// TreeSubtreeExportRowTests.swift - The Operations row of the tree viewer's subtree export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row A15, ARCH ruling 1.5 rule 3. `PhylogeneticTreeViewController.beginSubtreeExportOperation`
// begins an export row with no lock and a cancel callback, records the `tree export subtree` command the runner
// runs, and launches nothing when the row is refused. `runSubtreeExport` passes `--force` only when the output exists
// (ARCH 1.2). TreeSubtreeExportCLIGUIParityReplayTests runs the command.

import XCTest
@testable import LungfishCLI
@testable import LungfishPhylogeneticsUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class SubtreeExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class TreeSubtreeExportRowTests: XCTestCase {
    private let exportInvocation = TreeSubtreeExport.invocation(
        bundleURL: URL(fileURLWithPath: "/tmp/lane 12.35/Project/Trees/primates.lungfishtree", isDirectory: true),
        nodeID: "node-7",
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.35/Clade, reviewed.nwk"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(PhylogeneticTreeViewController.beginSubtreeExportOperation(
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
        XCTAssertEqual(item.title, "Export Subtree")
        XCTAssertEqual(item.initialDetail, "Writing Clade, reviewed.nwk")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: TreeCommand.ExportSubcommand.SubtreeSubcommand.self)
        XCTAssertEqual(command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.bundlePath, "/tmp/lane 12.35/Project/Trees/primates.lungfishtree")
        XCTAssertEqual(command.nodeID, "node-7")
        XCTAssertNil(command.label)
        XCTAssertEqual(command.outputFormat, "newick")
        XCTAssertEqual(command.outputPath, "/tmp/lane 12.35/Clade, reviewed.nwk")
        XCTAssertTrue(command.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = PhylogeneticTreeViewController.beginSubtreeExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: TreeCommand.ExportSubcommand.SubtreeSubcommand.self
        )
        XCTAssertEqual(command.invocation(), exportInvocation)
    }

    /// The alert of `exportSelectedSubtree` shows what `onFailure` gets. A leaf that fails fails the run, and
    /// `onFailure` gets its message once (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = SubtreeExportFailureCalls()
        let begun = try XCTUnwrap(PhylogeneticTreeViewController.beginSubtreeExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    /// ARCH 1.2. `--force` is passed only when the file the save panel returned exists.
    func testForceIsPassedOnlyOnReplace() async throws {
        let root = try TestTempDirectory.make(prefix: "tree-subtree-row")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("tree.lungfishtree", isDirectory: true)
        let output = root.appendingPathComponent("clade.nwk")

        let first = try await runAndParse(bundle: bundle, output: output)
        XCTAssertFalse(first.force, "a new file is not replaced")
        XCTAssertEqual(first.bundlePath, bundle.standardizedFileURL.path)
        XCTAssertEqual(first.nodeID, "node-3")

        try Data("();\n".utf8).write(to: output)
        let second = try await runAndParse(bundle: bundle, output: output)
        XCTAssertTrue(second.force, "the save panel's Replace replaces the file")
    }

    private func runAndParse(bundle: URL, output: URL) async throws -> TreeCommand.ExportSubcommand.SubtreeSubcommand {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(PhylogeneticTreeViewController.runSubtreeExport(
            bundleURL: bundle,
            nodeID: "node-3",
            outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value
        return try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: TreeCommand.ExportSubcommand.SubtreeSubcommand.self
        )
    }
}
