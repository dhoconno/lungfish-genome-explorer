// TwelveSSavedBlastRestoreTests.swift - A saved BLAST search comes back when its 12S sequences are selected again
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN2, item 2. A 12S search's lineage names only its bundle, so its own query tells one selection's
// search from another's. Its plan saves under the project, so the records here sit there. These tests extend the
// controller's test class for its result builder.

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishTwelveSUI

extension TwelveSAmpliconResultViewControllerTests {
    /// A viewer of `name` in `project`, on its Unresolved list with both sequences showing and no row selected.
    private func makeRestoreViewer(
        result name: String,
        in project: SavedBlastSearchProject
    ) throws -> (viewer: TwelveSAmpliconResultViewController, rows: [(id: String, sequence: String)]) {
        let viewer = TwelveSAmpliconResultViewController()
        isolateLayouts(viewer)
        viewer.loadViewIfNeeded()
        viewer.configure(result: makeResult(bundleURL: try project.result(name)))
        let projectURL = project.project
        viewer.savedBlastSearchProject = { projectURL }
        viewer.applyDisplayState(TwelveSResultDisplayState(minimumUnresolvedReads: 1))
        viewer.showUnresolvedForTesting()
        let rows = viewer.selectedUnresolvedRows().map { (id: $0.sequenceID, sequence: $0.sequence) }
        XCTAssertEqual(rows.count, 2)
        return (viewer, rows)
    }

    private func settle(_ viewer: TwelveSAmpliconResultViewController) async {
        await viewer.savedBlastRestorer.restoreTask?.value
    }

    func testTwelveSSelectionRestoresOnlyItsOwnResultsSavedSearch() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        _ = try project.result("B.lungfish12s")
        let (viewer, rows) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        let recordA = try project.saveRecord(rid: "RID-A", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil, querySequences: [rows[0]])
        try project.saveRecord(rid: "RID-B", sourceResult: "B.lungfish12s", sample: nil, taxId: nil, contig: nil, age: -60, querySequences: [rows[0]])

        viewer.testingSelectUnresolvedRow(0)
        await settle(viewer)

        let pane = try XCTUnwrap(viewer.blastDrawerContainer?.blastResultsTab, "the selection's search opens the pane")
        XCTAssertEqual(pane.currentResult?.rid, "RID-A")
        XCTAssertEqual(pane.currentRecordURL?.standardizedFileURL.path, recordA.standardizedFileURL.path, "the export reads this file")
        guard case .sequenceBlast = pane.presentationStyle else { return XCTFail("the pane keeps its sequence style") }
        XCTAssertTrue(viewer.isBlastDrawerOpen, "no control opens this viewer's pane, so a restore opens it")
    }

    func testAnotherTwelveSSelectionInTheSameResultDoesNotShowIt() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let (viewer, rows) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        try project.saveRecord(rid: "RID-ONE", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil, querySequences: [rows[0]])

        viewer.testingSelectUnresolvedRow(1)
        await settle(viewer)
        XCTAssertNil(viewer.blastDrawerContainer, "another sequence's selection has no saved search")
    }

    func testATwelveSSearchOfEveryShownSequenceComesBackWithNoRowSelected() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let (first, rows) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        try project.saveRecord(rid: "RID-ALL", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil, querySequences: rows.reversed())

        first.testingSelectUnresolvedRow(0)
        await settle(first)
        XCTAssertNil(first.blastDrawerContainer, "one row of the two is another selection")

        // A person who comes back gets a new viewer and goes to its Unresolved list with no row selected.
        let (viewer, _) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        await settle(viewer)
        XCTAssertEqual(viewer.blastDrawerContainer?.blastResultsTab.currentResult?.rid, "RID-ALL")
    }

    func testATwelveSScanAfterTheSelectionMovedIsDropped() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let (viewer, rows) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        try project.saveRecord(rid: "RID-ONE", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil, querySequences: [rows[0]])

        viewer.testingSelectUnresolvedRow(0)
        let scan = try XCTUnwrap(viewer.savedBlastRestorer.restoreTask)
        viewer.testingSelectUnresolvedRow(1)
        await scan.value
        await settle(viewer)

        XCTAssertNil(viewer.blastDrawerContainer)
    }

    func testATwelveSRunIsNotReplacedAndARestoreFollowsItsEnd() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let (viewer, rows) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        try project.saveRecord(rid: "RID-ONE", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil, querySequences: [rows[0]])

        viewer.showBlastLoading(phase: .submitting, requestId: nil)
        viewer.testingSelectUnresolvedRow(0)
        XCTAssertNil(viewer.savedBlastRestorer.restoreTask, "a run in flight starts no scan")
        let pane = try XCTUnwrap(viewer.blastDrawerContainer?.blastResultsTab)
        XCTAssertNil(pane.currentResult)

        viewer.showBlastFailure("The search stopped.")
        viewer.testingSelectUnresolvedRow(1)
        viewer.testingSelectUnresolvedRow(0)
        await settle(viewer)
        XCTAssertEqual(pane.currentResult?.rid, "RID-ONE")
    }

    /// IDs are ranks. A re-run with Replace Existing Bundle writes a new bundle at the same path, where `unresolved_1` names
    /// another sequence, so a search of the earlier bundle's `unresolved_1` is not this row's search (REOPEN2-BIO B1).
    func testATwelveSSelectionDoesNotShowASearchOfAnEarlierBundleWithTheSameIDs() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let (viewer, rows) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        try project.saveRecord(
            rid: "RID-EARLIER", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil,
            querySequences: [(id: rows[0].id, sequence: "TTTTTTTT")]
        )

        viewer.testingSelectUnresolvedRow(0)
        await settle(viewer)

        XCTAssertNil(viewer.blastDrawerContainer, "the same ID with another sequence is another search")
    }

    func testATwelveSSearchOfEveryRowDoesNotComeBackWhenOneSequenceDiffers() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let (_, rows) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        try project.saveRecord(
            rid: "RID-EARLIER", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil,
            querySequences: [rows[0], (id: rows[1].id, sequence: "TTTTTTTT")]
        )

        let (viewer, _) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        await settle(viewer)

        XCTAssertNil(viewer.blastDrawerContainer, "the same count of rows is not the same search")
    }

    func testTheNewestTwelveSRecordWinsAndAFolderWithNoReadableRecordIsSkipped() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let (viewer, rows) = try makeRestoreViewer(result: "A.lungfish12s", in: project)
        try project.saveRecord(rid: "RID-OLD", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil, age: 60, querySequences: [rows[0]])
        try project.saveRecord(rid: "RID-NEW", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil, querySequences: [rows[0]])
        try project.saveRecord(rid: "RID-NO-QUERY", sourceResult: "A.lungfish12s", sample: nil, taxId: nil, contig: nil, age: -60)
        try project.saveFolderWithNoReadableRecord(named: "timed-out")

        viewer.testingSelectUnresolvedRow(0)
        await settle(viewer)

        XCTAssertEqual(viewer.blastDrawerContainer?.blastResultsTab.currentResult?.rid, "RID-NEW")
    }
}
