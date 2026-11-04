// ClassifierResultActionsBlastRestoreTests.swift - When a saved BLAST search comes back to the shared pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN (BLAST-RESULT-NOT-REOPENED). The viewer tests show that a row finds its own record. These hold
// the pane's rules, each with the scan's task to await, so no test sleeps.

import AppKit
import LungfishCore
import LungfishKit
import LungfishTestSupport
import XCTest

@MainActor
final class ClassifierResultActionsBlastRestoreTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var actions: ClassifierResultActions!
    private var rowA: BlastSavedSearchRow!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
        saved = try SavedBlastSearchProject()
        actions = ClassifierResultActions()
        rowA = BlastSavedSearchRow(sourceResultURL: try saved.result("result-A"), sample: "S1", taxId: 7, contig: "NC_1")
        try saved.saveRecord(rid: "RID-A", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1")
    }

    override func tearDown() async throws {
        actions = nil
        saved?.remove()
        try await super.tearDown()
    }

    private func select(_ row: BlastSavedSearchRow?) async {
        actions.showSelection(count: 1, blastRow: row)
        await actions.savedBlastRestoreTask?.value
    }

    func testARestoredSearchSetsItsRecordFileAndLeavesThePaneClosed() async throws {
        await select(rowA)

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-A")
        XCTAssertEqual(actions.lastBlastRecordURL?.lastPathComponent, BlastSubmissionRecord.recordFileName)
        XCTAssertFalse(actions.isBlastDrawerOpen)
        XCTAssertEqual(actions.blastResultsButton.state, .off)
    }

    func testARestoredSearchLeavesAnOpenPaneOpen() async throws {
        actions.setBlastDrawerOpen(true)

        await select(rowA)

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-A")
        XCTAssertTrue(actions.isBlastDrawerOpen)
    }

    /// BLAST-STALE-PANE-TAXON-ONLY (BIO, lane ROWPANE). The pane shows the selected row's search or nothing, so a row
    /// with no saved search empties a pane that shows another row's search. This test pinned the opposite before.
    func testRowWithNoSavedSearchEmptiesThePaneOfAnotherRowsSearch() async throws {
        await select(rowA)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-A")
        let other = try rowWithNoSearch("NC_NONE")

        await select(other)

        XCTAssertNil(actions.lastBlastResult, "row A's verdict does not stay under a row with no search")
        XCTAssertNil(actions.lastBlastRecordURL)
        XCTAssertNil(actions.restoredBlastRow)
        XCTAssertNil(actions.blastDrawer.currentResult, "the pane shows its empty state")
        XCTAssertTrue(actions.blastDrawer.emptyStateDetailText.contains("Select a row"), actions.blastDrawer.emptyStateDetailText)
    }

    /// A nil row picks no single row, so the pane makes no claim about a row and keeps what it shows.
    func testNoSingleRowKeepsThePane() async throws {
        await select(rowA)

        actions.showSelection(count: 2)
        actions.showNoSelection(prompt: "")

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-A")
        XCTAssertEqual(actions.restoredBlastRow, rowA)
    }

    /// The same rule for a run. A result a run brought belongs to the row picked when the run began, and it empties
    /// when a row with no saved search is picked.
    func testARunsResultDoesNotStayUnderAnotherRowWithNoSearch() async throws {
        let rowB = try rowWithNoSearch("NC_B")
        let rowC = try rowWithNoSearch("NC_C")
        await select(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.showBlastResults(try runResult(), recordURL: nil)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-RUN")

        await select(rowC)

        XCTAssertNil(actions.lastBlastResult, "row B's run result does not stay under row C")
        XCTAssertNil(actions.blastDrawer.currentResult)
    }

    /// The pin that keeps the rule from over-reaching. A run's result stays when its own row is picked again, even
    /// when no saved record is found for the row.
    func testARunsResultStaysWhenItsOwnRowIsPickedAgain() async throws {
        let rowB = try rowWithNoSearch("NC_B")
        await select(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.showBlastResults(try runResult(), recordURL: nil)

        await select(rowB)

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-RUN", "the run's result is row B's own")
    }

    // MARK: - The summary names the sample (BIO, lane ROWPANE, review blocker 1)

    /// Two samples can hold one taxon, so the taxon alone does not tell a person whose reads a verdict counts. The
    /// summary names the sample of the row the pane shows.
    func testPaneSummaryNamesTheSampleOfTheRowItShows() async throws {
        await select(rowA)

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains(try XCTUnwrap(rowA.sample)), summary)
    }

    /// A run that finishes after the person moved to another sample's row. Its verdict is about the sample it ran on.
    func testARunsVerdictNamesTheSampleItRanOn() async throws {
        let rowB = try rowOfSample("S2")
        let rowC = try rowOfSample("S3")
        await select(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        await select(rowC)
        XCTAssertNil(actions.savedBlastRestoreTask, "no scan starts while a run is in flight")

        actions.showBlastResults(try runResult(), recordURL: nil)

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("S2"), summary)
        XCTAssertFalse(summary.contains("S3"), summary)
    }

    /// No single row is picked, so the pane keeps the verdict it shows (BIO's ruling) and the summary still says whose it is.
    func testASavedVerdictKeepsNamingItsSampleWhenNoSingleRowIsPicked() async throws {
        await select(rowA)

        actions.showSelection(count: 2)
        actions.showNoSelection(prompt: "")

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-A")
        XCTAssertTrue(summary.contains("S1"), summary)
    }

    /// A run that finishes while no single row is picked still names the sample it ran on.
    func testARunsVerdictNamesItsSampleWhenNoSingleRowIsPicked() async throws {
        let rowB = try rowOfSample("S2")
        await select(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.showSelection(count: 2)

        actions.showBlastResults(try runResult(), recordURL: nil)

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("S2"), summary)
    }

    /// UX blocker 1 of lane ROWPANE. A context-menu command acts on the clicked row when that row lies outside the
    /// selection, so the viewer names the row of the run it hands over. The verdict names that row's sample, and it
    /// stays under that row, never under the picked row.
    func testARunNamesTheRowItWasSentForNotThePickedRow() async throws {
        let rowB = try rowOfSample("S2")
        await select(rowA)
        actions.noteBlastRunRow(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)

        actions.showBlastResults(try runResult(), recordURL: nil)

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("S2"), summary)
        XCTAssertFalse(summary.contains("S1"), summary)
        await select(rowB)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-RUN", "the verdict stays under the row it was sent for")
        await select(try rowWithNoSearch("NC_OTHER"))
        XCTAssertNil(actions.lastBlastResult, "another row with no search empties the pane")
    }

    /// A name belongs to the next run only. A hand-off that began no run, then a selection change, leaves it dropped,
    /// and a run that began after its own name used it up names the row picked.
    func testANamedRowNeverNamesAnotherRun() async throws {
        let rowB = try rowOfSample("S2")
        let rowC = try rowOfSample("S3")
        await select(rowC)
        actions.noteBlastRunRow(rowB)
        await select(rowC)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.showBlastResults(try runResult(), recordURL: nil)
        let afterADropped = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(afterADropped.contains("S3"), afterADropped)
        XCTAssertFalse(afterADropped.contains("S2"), afterADropped)

        actions.noteBlastRunRow(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.showBlastFailure("NCBI did not answer.")
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.showBlastResults(try runResult(), recordURL: nil)
        let afterAUsed = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(afterAUsed.contains("S3"), afterAUsed)
        XCTAssertFalse(afterAUsed.contains("S2"), afterAUsed)
    }

    /// A run whose operation ended without a word to the pane (a Cancel) is over. The next run is about the row
    /// its viewer names, and the cancelled run's row does not name it.
    func testARunAfterACancelledRunIsNamedForItsOwnRow() async throws {
        let rowB = try rowOfSample("S2")
        await select(rowA)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.trackBlastRun(operationID: UUID())

        actions.noteBlastRunRow(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.showBlastResults(try runResult(), recordURL: nil)

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("S2"), summary)
        XCTAssertFalse(summary.contains("S1"), summary)
    }

    /// A second search that begins while the first still runs shares one pane with it, so neither
    /// verdict can be told from the other's row. The verdict names no sample rather than the wrong one.
    func testASecondSearchWhileOneRunsNamesNoSampleOverTheOthersVerdict() async throws {
        let center = OperationCenter.shared
        let first = center.begin(
            title: "BLAST second search test", detail: "Running", operationType: .blastVerification, cliCommand: "lungfish-cli blast submit"
        ).rowID
        let second = center.begin(
            title: "BLAST second search test", detail: "Running", operationType: .blastVerification, cliCommand: "lungfish-cli blast submit"
        ).rowID
        defer {
            center.clearItem(id: first)
            center.clearItem(id: second)
        }
        let rowB = try rowOfSample("S2")
        await select(rowA)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.trackBlastRun(operationID: first)

        actions.noteBlastRunRow(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.trackBlastRun(operationID: second)
        actions.showBlastResults(try runResult(), recordURL: nil)

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertFalse(summary.contains("S1"), "the first search's row does not name the second's verdict: \(summary)")
        XCTAssertFalse(summary.contains("S2"), "the second search's row does not name a verdict that may be the first's: \(summary)")
    }

    /// Row A with another sample, so two rows differ by sample alone.
    private func rowOfSample(_ sample: String) throws -> BlastSavedSearchRow {
        var row = try XCTUnwrap(rowA)
        row.sample = sample
        return row
    }

    private func rowWithNoSearch(_ contig: String) throws -> BlastSavedSearchRow {
        var row = try XCTUnwrap(rowA)
        row.contig = contig
        return row
    }

    /// A result a run brought, read from a record that no row of these tests selects.
    private func runResult() throws -> BlastVerificationResult {
        let recordURL = try saved.saveRecord(rid: "RID-RUN", sourceResult: "result-A", sample: "S9", taxId: 99, contig: "NC_RUN", age: -100)
        return try BlastSubmissionRecord.load(recordURL).result
    }

    func testARunInFlightIsNotReplacedAndARestoreFollowsItsEnd() async throws {
        actions.showBlastLoading(phase: .submitting, requestId: nil)

        await select(rowA)
        XCTAssertNil(actions.savedBlastRestoreTask, "no scan starts while a run is in flight")
        XCTAssertNil(actions.lastBlastResult)

        actions.showBlastFailure("NCBI did not answer.")
        await select(rowA)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-A")
    }

    func testAScanThatReturnsAfterTheSelectionMovedIsDropped() async throws {
        actions.showSelection(count: 1, blastRow: rowA)
        let scan = try XCTUnwrap(actions.savedBlastRestoreTask)

        actions.showNoSelection(prompt: "")
        await scan.value

        XCTAssertNil(actions.lastBlastResult)
    }

    func testAScanThatReturnsAfterARunBeganIsDropped() async throws {
        actions.showSelection(count: 1, blastRow: rowA)
        let scan = try XCTUnwrap(actions.savedBlastRestoreTask)

        actions.showBlastLoading(phase: .submitting, requestId: nil)
        await scan.value

        XCTAssertNil(actions.lastBlastResult)
    }

    /// A Cancel tells the pane nothing, so a run counts only while its operation is active, as Kraken2's does.
    func testARunWhoseOperationEndedNoLongerBlocksARestore() async throws {
        let center = OperationCenter.shared
        let id = center.begin(
            title: "BLAST restore test", detail: "Running", operationType: .blastVerification, cliCommand: "lungfish-cli blast submit"
        ).rowID
        defer { center.clearItem(id: id) }
        actions.trackBlastRun(operationID: id)
        actions.showBlastLoading(phase: .submitting, requestId: nil)

        await select(rowA)
        XCTAssertNil(actions.lastBlastResult, "the run's operation is active")

        XCTAssertTrue(center.complete(id: id, detail: "ended"))
        await select(rowA)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-A")
    }

    func testAPaneThatShowsThisRowsSearchStartsNoScan() async throws {
        await select(rowA)

        actions.showSelection(count: 1, blastRow: rowA)

        XCTAssertNil(actions.savedBlastRestoreTask)
    }

    func testARunsOwnResultIsNotReplacedByItsOwnRecord() async throws {
        let recordURL = try saved.saveRecord(rid: "RID-RUN", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1", age: -100)
        let run = try BlastSubmissionRecord.load(recordURL).result
        actions.showBlastResults(run, recordURL: recordURL)

        await select(rowA)

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-RUN")
        XCTAssertNil(actions.restoredBlastRow, "the pane still shows the run's own result")
    }

    /// The App names the project the plans save under, which may not be the one that holds the result.
    func testTheAppsProjectIsReadAndASelectionBeforeItsWiringStillRestores() async throws {
        let elsewhere = try SavedBlastSearchProject()
        defer { elsewhere.remove() }
        let result = try elsewhere.result("result-E")
        var row = try XCTUnwrap(rowA)
        row.sourceResultURL = result
        try saved.saveRecord(rid: "RID-E", sourceResult: "../../\(result.path)", sample: "S1", taxId: 7, contig: "NC_1")
        let recordFolder = saved.project.appendingPathComponent("blast-verifications/search-RID-E")
        var record = try BlastSubmissionRecord.load(recordFolder.appendingPathComponent(BlastSubmissionRecord.recordFileName))
        record.lineage.sourceResult = result.path
        try BlastSubmissionRecord.encoder.encode(record).write(to: recordFolder.appendingPathComponent(BlastSubmissionRecord.recordFileName))

        await select(row)
        XCTAssertNil(actions.lastBlastResult, "the result's own project holds no search of this row")

        let project = saved.project
        actions.savedBlastSearchProject = { project }
        await actions.savedBlastRestoreTask?.value

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-E")
    }
}
