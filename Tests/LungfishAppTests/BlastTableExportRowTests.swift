// BlastTableExportRowTests.swift - The Operations row of the BLAST drawer's table export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.33, ARCH ruling T5 condition 3 and ruling 1.5 rule 3. `BlastResultsDrawerTab.beginBlastTableExportOperation`
// begins an export row with no lock and a cancel callback, records the `blast export table` command the runner
// runs, launches nothing when the row is refused, and hands a failed leaf's message to `onFailure` (UX 4). The
// parity class of the same lane runs the command.

import XCTest
@testable import LungfishCLI
@testable import LungfishKit
import LungfishCore
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
private final class FailureCalls {
    var messages: [String] = []
}

@MainActor
final class BlastTableExportRowTests: XCTestCase {
    private let exportInvocation = BlastVerificationTableExport.invocation(
        recordURL: URL(
            fileURLWithPath: "/tmp/lane 12.33/Project.lungfish/Analyses/kraken2-run/blast-verifications/Escherichia-coli-a/blast-result.json"
        ),
        format: .csv,
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.33/blast hits, all.csv"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(BlastResultsDrawerTab.beginBlastTableExportOperation(
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
        XCTAssertEqual(item.title, "Export BLAST Table")
        XCTAssertEqual(item.initialDetail, "Writing blast hits, all.csv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.ExportTableSubcommand.self)
        XCTAssertEqual(command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.output.path, "/tmp/lane 12.33/blast hits, all.csv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = BlastResultsDrawerTab.beginBlastTableExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: BlastCommand.ExportTableSubcommand.self
        )
        XCTAssertEqual(command.invocation(), exportInvocation)
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once. The drawer passes that to
    /// `ResultExportCoordinator.reportFailure`, so a failed export is no longer only a log line (UX 4).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = FailureCalls()
        let begun = try XCTUnwrap(BlastResultsDrawerTab.beginBlastTableExportOperation(
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
