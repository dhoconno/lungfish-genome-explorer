// EsVirituSavedBlastRestoreTests.swift - An EsViritu row shows its own saved BLAST search again
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN (BLAST-RESULT-NOT-REOPENED, S2, O115). An EsViritu search records no tax ID, so a row matches
// on its result, its sample and the accessions it searched.

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishEsVirituUI

@MainActor
final class EsVirituSavedBlastRestoreTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var controller: EsVirituResultViewController!

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
        try saved.saveRecord(rid: "RID-A", sourceResult: "esviritu-A", sample: "A", taxId: nil, contig: "NC_X.1", age: 100)
        try saved.saveRecord(rid: "RID-B", sourceResult: "esviritu-B", sample: "A", taxId: nil, contig: "NC_X.1")
        try openResult(samples: ["A", "B"], accessions: ["NC_X.1"])

        controller.testDetectionTableView.onDetectionSelected?(Self.detection(sample: "A", accession: "NC_X.1"))

        let shown = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.resultActions.lastBlastResult != nil }
        XCTAssertTrue(shown, "the row's saved search comes back")
        XCTAssertEqual(controller.resultActions.lastBlastResult?.rid, "RID-A", "the newer search of result B is not this row's")
        XCTAssertFalse(controller.resultActions.isBlastDrawerOpen, "a restored search does not open the pane")
    }

    func testTheSameAccessionInTwoSamplesShowsEachSamplesOwnRecord() async throws {
        try saved.saveRecord(rid: "RID-S-A", sourceResult: "esviritu-A", sample: "A", taxId: nil, contig: "NC_X.1")
        try saved.saveRecord(rid: "RID-S-B", sourceResult: "esviritu-A", sample: "B", taxId: nil, contig: "NC_X.1")
        try openResult(samples: ["A", "B"], accessions: ["NC_X.1"])
        let table = controller.testDetectionTableView

        table.onDetectionSelected?(Self.detection(sample: "B", accession: "NC_X.1"))
        let second = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.resultActions.lastBlastResult?.rid == "RID-S-B" }
        XCTAssertTrue(second, "sample B's row shows sample B's search")

        table.onDetectionSelected?(Self.detection(sample: "A", accession: "NC_X.1"))
        let first = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.resultActions.lastBlastResult?.rid == "RID-S-A" }
        XCTAssertTrue(first, "sample A's row shows sample A's search")
    }

    /// An assembly row searches all its contigs, so its record names them all. A contig row of that assembly names one.
    func testAnAssemblyRowMatchesTheSearchOfAllItsContigs() async throws {
        try saved.saveRecord(rid: "RID-CONTIG", sourceResult: "esviritu-A", sample: "A", taxId: nil, contig: "NC_X.1")
        try saved.saveRecord(rid: "RID-ASSEMBLY", sourceResult: "esviritu-A", sample: "A", taxId: nil, contig: "NC_X.1,NC_X.2", age: 100)
        try openResult(samples: ["A"], accessions: ["NC_X.1", "NC_X.2"])

        controller.testDetectionTableView.testOutlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let shown = await waitUntil(timeout: WaitBudget.lookup.duration) { self.controller.resultActions.lastBlastResult != nil }
        XCTAssertTrue(shown, "the assembly row's saved search comes back")
        XCTAssertEqual(controller.resultActions.lastBlastResult?.rid, "RID-ASSEMBLY")
    }

    private func openResult(samples: [String], accessions: [String]) throws {
        let result = try saved.result("esviritu-A")
        let rows = samples.flatMap { sample in accessions.map { Self.row(sample: sample, accession: $0) } }
        let database = try EsVirituDatabase.create(
            at: result.appendingPathComponent("esviritu.sqlite"), rows: rows, metadata: ["tool": "test"]
        )
        controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { UnavailableClassifierAlignmentViewer() }
        let layouts = makeTestDefaultsSuite(prefix: "EsVirituSavedBlastRestoreTests")
        controller.testDetectionTableView.metadataColumns.userDefaults = layouts.defaults
        controller.testBatchTableView.metadataColumns.userDefaults = layouts.defaults
        _ = controller.view
        controller.configureFromDatabase(database, resultURL: result)
    }

    private static func detection(sample: String, accession: String) -> ViralDetection {
        ViralDetection(
            sampleId: sample, name: "Virus X", description: "", length: 4_200, segment: nil,
            accession: accession, assembly: "ASM_X", assemblyLength: 4_200,
            kingdom: nil, phylum: nil, tclass: nil, order: nil, family: nil, genus: nil, species: nil, subspecies: nil,
            rpkmf: 1, readCount: 50, coveredBases: 4_200, meanCoverage: 1, avgReadIdentity: 0.99, pi: 0,
            filteredReadsInSample: 100
        )
    }

    private static func row(sample: String, accession: String) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample, virusName: "Virus X", description: nil, contigLength: 4_200, segment: nil,
            accession: accession, assembly: "ASM_X", assemblyLength: 4_200, kingdom: nil, phylum: nil, tclass: nil,
            torder: nil, family: nil, genus: nil, species: nil, subspecies: nil, rpkmf: 1, readCount: 50, uniqueReads: 40,
            coveredBases: 4_200, meanCoverage: 1, avgReadIdentity: 0.99, pi: nil, filteredReadsInSample: 100,
            bamPath: nil, bamIndexPath: nil
        )
    }
}
