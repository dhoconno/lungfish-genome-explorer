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

    func testARowWithNoSavedRecordLeavesThePaneAsItIs() async throws {
        await select(rowA)
        var other = try XCTUnwrap(rowA)
        other.contig = "NC_NONE"

        await select(other)

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-A", "the pane is not cleared")
        XCTAssertEqual(actions.restoredBlastRow, rowA)
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
