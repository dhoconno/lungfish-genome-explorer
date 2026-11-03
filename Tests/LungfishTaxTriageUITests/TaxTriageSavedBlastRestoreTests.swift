// TaxTriageSavedBlastRestoreTests.swift - A TaxTriage row shows its own saved BLAST search again
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN (BLAST-RESULT-NOT-REOPENED, S2, O115). A TaxTriage row matches on its result, its sample, its
// tax ID and the accessions it searched.

import AppKit
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

        let shown = await waitUntil { self.controller.resultActions.lastBlastResult != nil }
        XCTAssertTrue(shown, "the row's saved search comes back")
        XCTAssertEqual(controller.resultActions.lastBlastResult?.rid, "RID-A", "the newer search of result B is not this row's")
        XCTAssertFalse(controller.resultActions.isBlastDrawerOpen, "a restored search does not open the pane")
    }

    func testTheSameTaxonInTwoSamplesShowsEachSamplesOwnRecord() async throws {
        try saved.saveRecord(rid: "RID-S-1", sourceResult: "taxtriage-A", sample: "sample-1", taxId: 1001, contig: "NC_1001")
        try saved.saveRecord(rid: "RID-S-2", sourceResult: "taxtriage-A", sample: "sample-2", taxId: 1001, contig: "NC_1001")
        try await openResult()

        try select(sample: "sample-2")
        let second = await waitUntil { self.controller.resultActions.lastBlastResult?.rid == "RID-S-2" }
        XCTAssertTrue(second, "sample 2's row shows sample 2's search")

        try select(sample: "sample-1")
        let first = await waitUntil { self.controller.resultActions.lastBlastResult?.rid == "RID-S-1" }
        XCTAssertTrue(first, "sample 1's row shows sample 1's search")
    }

    private func openResult() async throws {
        let result = try saved.result("taxtriage-A")
        for sample in ["sample-1", "sample-2"] {
            let folder = result.appendingPathComponent("\(sample)/minimap2", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("\(sample).bam"))
            try Data().write(to: folder.appendingPathComponent("\(sample).bam.bai"))
        }
        let rows = [Self.row(sample: "sample-1"), Self.row(sample: "sample-2")]
        let database = try TaxTriageDatabase.create(
            at: result.appendingPathComponent("taxtriage.sqlite"), rows: rows, metadata: ["tool": "taxtriage"]
        )
        controller = TaxTriageResultViewController()
        let layouts = makeTestDefaultsSuite(prefix: "TaxTriageSavedBlastRestoreTests")
        controller.testBatchFlatTableView.metadataColumns.userDefaults = layouts.defaults
        _ = controller.view
        controller.configureFromDatabase(database, resultURL: result)
        let loaded = await waitUntil { self.controller.testBatchFlatTableView.displayedRows.count == rows.count }
        XCTAssertTrue(loaded, "the rows load")
    }

    private func select(sample: String) throws {
        let table = controller.testBatchFlatTableView
        let index = try XCTUnwrap(table.displayedRows.firstIndex { $0.sample == sample })
        table.selectDisplayedRowForContextMenuIfNeeded(index)
    }

    private static func row(sample: String) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9, readsAligned: 40,
            uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
            meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
            diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: "\(sample)/minimap2/\(sample).bam", bamIndexPath: "\(sample)/minimap2/\(sample).bam.bai",
            primaryAccession: "NC_1001", accessionLength: 10_000
        )
    }
}
