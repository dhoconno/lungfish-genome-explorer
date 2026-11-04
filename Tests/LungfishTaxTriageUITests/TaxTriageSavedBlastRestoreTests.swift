// TaxTriageSavedBlastRestoreTests.swift - A TaxTriage row shows its own saved BLAST search again
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN (BLAST-RESULT-NOT-REOPENED, S2, O115). A TaxTriage row matches on its result, its sample, its
// tax ID and the accessions it searched.

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageSavedBlastRestoreTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var controller: TaxTriageResultViewController!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        saved = try SavedBlastSearchProject()
    }

    override func tearDown() async throws {
        controller = nil
        saved?.remove()
        try await super.tearDown()
    }

    func testClassifierRowRestoresOnlyItsOwnResultsSavedSearch() async throws {
        try saved.saveRecord(rid: "RID-A", sourceResult: "taxtriage-A", sample: "sample-1", taxId: 1001, contig: "NC_1001", age: 100)
        try saved.saveRecord(rid: "RID-B", sourceResult: "taxtriage-B", sample: "sample-1", taxId: 1001, contig: "NC_1001")
        try await openResult()

        try select(sample: "sample-1")

        let shown = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.resultActions.lastBlastResult != nil }
        XCTAssertTrue(shown, "the row's saved search comes back")
        XCTAssertEqual(controller.resultActions.lastBlastResult?.rid, "RID-A", "the newer search of result B is not this row's")
        XCTAssertFalse(controller.resultActions.isBlastDrawerOpen, "a restored search does not open the pane")
    }

    func testTheSameTaxonInTwoSamplesShowsEachSamplesOwnRecord() async throws {
        try saved.saveRecord(rid: "RID-S-1", sourceResult: "taxtriage-A", sample: "sample-1", taxId: 1001, contig: "NC_1001")
        try saved.saveRecord(rid: "RID-S-2", sourceResult: "taxtriage-A", sample: "sample-2", taxId: 1001, contig: "NC_1001")
        try await openResult()

        try select(sample: "sample-2")
        let second = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.resultActions.lastBlastResult?.rid == "RID-S-2" }
        XCTAssertTrue(second, "sample 2's row shows sample 2's search")

        try select(sample: "sample-1")
        let first = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.resultActions.lastBlastResult?.rid == "RID-S-1" }
        XCTAssertTrue(first, "sample 1's row shows sample 1's search")
    }

    /// The view holds the request of row B when row A's saved search comes back. Run Again then repeats row A's sample,
    /// accessions, BAM and index, since the pane names row A.
    func testRunAgainOnARestoredSearchRepeatsThatRowsRequest() async throws {
        try saved.saveRecord(rid: "RID-A", sourceResult: "taxtriage-A", sample: "sample-1", taxId: 1001, contig: "NC_1001")
        try await openResult(secondSampleAccession: "NC_2002")
        var forwarded: [(sample: String?, accessions: [String]?, bamURL: URL?, bamIndexURL: URL?)] = []
        controller.onBlastVerification = { organism, _, accessions, bamURL, bamIndexURL in
            forwarded.append((organism.sample, accessions, bamURL, bamIndexURL))
        }
        controller.blastConfigPopoverPresenter = { _, _, _, onRun in onRun(20) }

        try select(sample: "sample-2")
        controller.testActionBar.blastButton.performClick(nil)
        XCTAssertEqual(forwarded.last?.sample, "sample-2", "row B's request is the one the view now holds")

        try select(sample: "sample-1")
        let shown = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.resultActions.lastBlastResult?.rid == "RID-A" }
        XCTAssertTrue(shown, "row A's saved search comes back")
        let drawer = controller.view.subviews.compactMap { $0 as? BlastResultsDrawerTab }.first
        try XCTUnwrap(drawer?.onRerunBlast, "the pane offers Run Again")()

        XCTAssertEqual(forwarded.count, 2, "Run Again reaches the host")
        XCTAssertEqual(forwarded.last?.sample, "sample-1")
        XCTAssertEqual(forwarded.last?.accessions, ["NC_1001"])
        XCTAssertEqual(forwarded.last?.bamURL?.lastPathComponent, "sample-1.bam")
        XCTAssertEqual(forwarded.last?.bamIndexURL?.lastPathComponent, "sample-1.bam.bai")
    }

    /// UX blocker 1 of lane ROWPANE. A context-menu command acts on the clicked row when that row lies outside the
    /// selection, and the selection stays where it is. The run is about the clicked row, so its verdict names that
    /// row's sample. At the base it named the selected row's sample over the clicked row's reads.
    func testARunStartedFromAClickedRowOutsideTheSelectionNamesThatRowsSample() async throws {
        try await openResult()
        try select(sample: "sample-1")
        await controller.resultActions.savedBlastRestoreTask?.value
        let actions = controller.resultActions
        var sent: [String?] = []
        // The App shows the run's progress at the top of its submit.
        controller.onBlastVerification = { organism, _, _, _, _ in
            sent.append(organism.sample)
            actions.showBlastLoading(phase: .submitting, requestId: nil)
        }
        let table = controller.testBatchFlatTableView
        let clicked = try XCTUnwrap(table.displayedRows.first { $0.sample == "sample-2" })

        table.onBlastVerifyRequested?(clicked, 20)

        XCTAssertEqual(sent, ["sample-2"], "the clicked row's reads are sent")
        let recordURL = try saved.saveRecord(
            rid: "RID-RUN", sourceResult: "taxtriage-A", sample: "sample-9", taxId: 99, contig: "NC_RUN", age: -100
        )
        actions.showBlastResults(try BlastSubmissionRecord.load(recordURL).result, recordURL: nil)
        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("sample-2"), "the verdict names the clicked row's sample: \(summary)")
        XCTAssertFalse(summary.contains("sample-1"), "the verdict does not name the selected row: \(summary)")
    }

    /// ROWPANE-UX-2 F1. Re-run repeats the request of the row the run was sent for (the clicked row's reads), so its
    /// verdict names that row's sample too. At the landed head the Re-run named no row and the pane took the pick.
    func testReRunAfterAClickedRowRunNamesTheClickedRowsSample() async throws {
        try await openResult()
        try select(sample: "sample-1")
        await controller.resultActions.savedBlastRestoreTask?.value
        let actions = controller.resultActions
        controller.onBlastVerification = { _, _, _, _, _ in
            actions.showBlastLoading(phase: .submitting, requestId: nil)
        }
        let table = controller.testBatchFlatTableView
        let clicked = try XCTUnwrap(table.displayedRows.first { $0.sample == "sample-2" })
        table.onBlastVerifyRequested?(clicked, 20)
        let recordURL = try saved.saveRecord(
            rid: "RID-RUN", sourceResult: "taxtriage-A", sample: "sample-9", taxId: 99, contig: "NC_RUN", age: -100
        )
        let result = try BlastSubmissionRecord.load(recordURL).result
        actions.showBlastResults(result, recordURL: nil)
        let drawer = controller.view.subviews.compactMap { $0 as? BlastResultsDrawerTab }.first

        try XCTUnwrap(drawer?.onRerunBlast, "the pane offers Re-run")()
        actions.showBlastResults(result, recordURL: nil)

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("sample-2"), "the Re-run's verdict names the sample of the row it repeats: \(summary)")
        XCTAssertFalse(summary.contains("sample-1"), "the Re-run's verdict does not name the selected row: \(summary)")
    }

    private func openResult(secondSampleAccession: String = "NC_1001") async throws {
        let result = try saved.result("taxtriage-A")
        for sample in ["sample-1", "sample-2"] {
            let folder = result.appendingPathComponent("\(sample)/minimap2", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("\(sample).bam"))
            try Data().write(to: folder.appendingPathComponent("\(sample).bam.bai"))
        }
        let rows = [Self.row(sample: "sample-1"), Self.row(sample: "sample-2", accession: secondSampleAccession)]
        let database = try TaxTriageDatabase.create(
            at: result.appendingPathComponent("taxtriage.sqlite"), rows: rows, metadata: ["tool": "taxtriage"]
        )
        controller = TaxTriageResultViewController()
        let layouts = makeTestDefaultsSuite(prefix: "TaxTriageSavedBlastRestoreTests")
        controller.testBatchFlatTableView.metadataColumns.userDefaults = layouts.defaults
        _ = controller.view
        controller.configureFromDatabase(database, resultURL: result)
        let loaded = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.testBatchFlatTableView.displayedRows.count == rows.count }
        XCTAssertTrue(loaded, "the rows load")
    }

    private func select(sample: String) throws {
        let table = controller.testBatchFlatTableView
        let index = try XCTUnwrap(table.displayedRows.firstIndex { $0.sample == sample })
        table.selectDisplayedRowForContextMenuIfNeeded(index)
    }

    private static func row(sample: String, accession: String = "NC_1001") -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9, readsAligned: 40,
            uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
            meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
            diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: "\(sample)/minimap2/\(sample).bam", bamIndexPath: "\(sample)/minimap2/\(sample).bam.bai",
            primaryAccession: accession, accessionLength: 10_000
        )
    }
}
