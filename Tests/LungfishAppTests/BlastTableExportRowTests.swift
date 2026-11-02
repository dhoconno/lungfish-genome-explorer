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

    private func walkFragment(rows otherMates: [BlastReadResult]?) -> BlastVerificationResult {
        let hits = ["PX372844", "OQ751369", "ON783971", "MN965909", "MN965880"].enumerated().map { index, accession in
            BlastHitSummary(
                rank: index + 1, accession: accession, organism: "Organism \(index)", taxId: 11676,
                percentIdentity: 100, queryCoverage: 100, eValue: 4.2664e-29, bitScore: 139.619, alignmentLength: 75
            )
        }
        return BlastVerificationResult(
            taxonName: "Human immunodeficiency virus 1", taxId: 11676,
            readResults: [BlastReadResult(
                id: "SRR12486983.3484597", verdict: .verified, topHits: hits, matchesQueriedTaxon: true, otherMates: otherMates
            )],
            submittedAt: Date(), completedAt: Date(), rid: "EGTB319K014", blastProgram: "blastn", database: "core_nt"
        )
    }

    /// Ruling BIO-BLAST-MATES Q2. One row per mate sent, deciding mate first, so `No significant hit` shows only on the mate it is true of.
    func testExportKeepsBothMatesOfAFragment() {
        let result = walkFragment(rows: [BlastReadResult(id: "SRR12486983.3484597", verdict: .unverified)])
        let rows = BlastVerificationTableExport.tableContent(result: result, separator: ",")
            .split(separator: "\n")
            .dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.count, 6, "five hit rows and one no-hit row")
        XCTAssertEqual(rows.prefix(5).map { $0[4] }, ["PX372844", "OQ751369", "ON783971", "MN965909", "MN965880"])
        XCTAssertEqual(rows.prefix(5).map { $0[1] }, Array(repeating: "verified", count: 5))
        XCTAssertEqual(rows.last?[0], "SRR12486983.3484597")
        XCTAssertEqual(rows.last?[1], "unverified")
        XCTAssertEqual(rows.last?[4], "")
    }

    /// `blast submit`'s complete message adds what was sent only when it differs from the rows counted, so the
    /// leaf's recorded event stays as it was for single reads.
    func testSubmitSummaryAddsTheSequencesSentOnlyWhenTheyDiffer() {
        XCTAssertEqual(
            BlastCommand.SubmitSubcommand.completionSummary(for: walkFragment(rows: [BlastReadResult(id: "SRR12486983.3484597", verdict: .unverified)])),
            "rid=EGTB319K014 supporting=1 contradicting=0 reads=1 sent=2"
        )
        XCTAssertEqual(
            BlastCommand.SubmitSubcommand.completionSummary(for: walkFragment(rows: nil)),
            "rid=EGTB319K014 supporting=1 contradicting=0 reads=1"
        )
    }
}
