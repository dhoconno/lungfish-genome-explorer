// HaplotypeDefinitionExportRowTests.swift - The Operations row of the haplotype manager's definition export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row B7, ARCH ruling 1.5 rule 3. `HaplotypeDefinitionManagerViewModel.beginDefinitionExportOperation`
// begins an export row with no lock and a cancel callback, records the `haplotypes export` command the runner runs
// with every option the export uses, which the leaf records as its argv, and launches nothing when the row is
// refused. HaplotypeDefinitionExportCLIGUIParityReplayTests runs the command.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class DefinitionExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class HaplotypeDefinitionExportRowTests: XCTestCase {
    static let outputURL = URL(fileURLWithPath: "/tmp/lane 12.35/MCM, reviewed.lungfishhaplotypedef.json")
    static let arguments = HaplotypeDefinitionExport.arguments(
        definitionID: "custom.export",
        outputPath: outputURL.path,
        projectPath: "/tmp/lane 12.35/Project/macaques.lungfish",
        assayID: "MHC-exon2-miSeq",
        scope: "project"
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(HaplotypeDefinitionManagerViewModel.beginDefinitionExportOperation(
            arguments: Self.arguments,
            outputURL: Self.outputURL,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        let outcome = await begun.task.value
        guard case .completed(let written) = outcome else { return XCTFail("a .result leaf's row completes on exit 0") }
        XCTAssertEqual(written.path, Self.outputURL.path)

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Haplotype Definition")
        XCTAssertEqual(item.initialDetail, "Writing MCM, reviewed.lungfishhaplotypedef.json")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: HaplotypeDefinitionsExportSubcommand.self)
        XCTAssertEqual(command.definitionID, "custom.export")
        XCTAssertEqual(command.output, Self.outputURL.path)
        XCTAssertEqual(command.project, "/tmp/lane 12.35/Project/macaques.lungfish")
        XCTAssertEqual(command.assay, "MHC-exon2-miSeq")
        XCTAssertEqual(command.scope, "project")
        let recorded = HaplotypeDefinitionExport.canonicalArgv(
            definitionID: command.definitionID,
            outputPath: command.output,
            projectPath: command.project,
            assayID: command.assay,
            scope: command.scope
        )
        XCTAssertEqual(recorded, [CLICommandIdentity.executableName] + Self.arguments, "the leaf records the row's command")
        XCTAssertFalse(Self.arguments.contains("--format"), "a .result leaf runs without --format json")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = HaplotypeDefinitionManagerViewModel.beginDefinitionExportOperation(
            arguments: Self.arguments,
            outputURL: Self.outputURL,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: HaplotypeDefinitionsExportSubcommand.self
        )
        XCTAssertEqual(command.definitionID, "custom.export")
    }

    /// The window shows what `onFailure` gets. A leaf that fails fails the run, and `onFailure` gets its message
    /// once (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = DefinitionExportFailureCalls()
        let begun = try XCTUnwrap(HaplotypeDefinitionManagerViewModel.beginDefinitionExportOperation(
            arguments: Self.arguments,
            outputURL: Self.outputURL,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }
}
