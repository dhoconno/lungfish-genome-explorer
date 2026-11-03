// NaoMgsSavedBlastRestoreTests.swift - A NAO-MGS row shows its own saved BLAST search again
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN (BLAST-RESULT-NOT-REOPENED, S2, O115). At the base nothing read a saved search back, so the
// pane read `No BLAST Verifications` once a person left a result. These searches sit in the project's folder, so a
// match on the tax ID alone would show another result's search on this row.

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishNaoMgsUI

@MainActor
final class NaoMgsSavedBlastRestoreTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var vc: NaoMgsResultViewController!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        saved = try SavedBlastSearchProject()
    }

    override func tearDown() async throws {
        vc = nil
        saved?.remove()
        try await super.tearDown()
    }

    func testClassifierRowRestoresOnlyItsOwnResultsSavedSearch() async throws {
        try saved.saveRecord(rid: "RID-A", sourceResult: "naomgs-A", sample: "sample-A", taxId: 1_000, contig: nil, age: 100)
        try saved.saveRecord(rid: "RID-B", sourceResult: "naomgs-B", sample: "sample-A", taxId: 1_000, contig: nil)
        try await openResult()

        try select(sample: "sample-A", taxId: 1_000)

        let shown = await waitUntil { self.vc.resultActions.lastBlastResult != nil }
        XCTAssertTrue(shown, "the row's saved search comes back")
        XCTAssertEqual(vc.resultActions.lastBlastResult?.rid, "RID-A", "the newer search of result B is not this row's")
        XCTAssertFalse(vc.resultActions.isBlastDrawerOpen, "a restored search does not open the pane")
    }

    func testTheSameTaxonInTwoSamplesShowsEachSamplesOwnRecord() async throws {
        try saved.saveRecord(rid: "RID-S-A", sourceResult: "naomgs-A", sample: "sample-A", taxId: 1_000, contig: nil)
        try saved.saveRecord(rid: "RID-S-B", sourceResult: "naomgs-A", sample: "sample-B", taxId: 1_000, contig: nil)
        try await openResult()

        try select(sample: "sample-B", taxId: 1_000)
        let second = await waitUntil { self.vc.resultActions.lastBlastResult?.rid == "RID-S-B" }
        XCTAssertTrue(second, "sample B's row shows sample B's search")

        try select(sample: "sample-A", taxId: 1_000)
        let first = await waitUntil { self.vc.resultActions.lastBlastResult?.rid == "RID-S-A" }
        XCTAssertTrue(first, "sample A's row shows sample A's search")
    }

    func testAFolderWithNoReadableRecordIsSkippedAndAnOlderGoodRecordShows() async throws {
        try saved.saveRecord(rid: "RID-OLD", sourceResult: "naomgs-A", sample: "sample-A", taxId: 1_000, contig: nil, age: 500)
        try saved.saveFolderWithNoReadableRecord(named: "search-timed-out")
        try await openResult()

        try select(sample: "sample-A", taxId: 1_000)

        let shown = await waitUntil { self.vc.resultActions.lastBlastResult?.rid == "RID-OLD" }
        XCTAssertTrue(shown, "the older good record shows")
    }

    func testTheNewestRecordOfTheRowWins() async throws {
        try saved.saveRecord(rid: "RID-OLDER", sourceResult: "naomgs-A", sample: "sample-A", taxId: 1_000, contig: nil, age: 500)
        try saved.saveRecord(rid: "RID-NEWER", sourceResult: "naomgs-A", sample: "sample-A", taxId: 1_000, contig: nil, age: 5)
        try await openResult()

        try select(sample: "sample-A", taxId: 1_000)

        let shown = await waitUntil { self.vc.resultActions.lastBlastResult != nil }
        XCTAssertTrue(shown, "the row's saved search comes back")
        XCTAssertEqual(vc.resultActions.lastBlastResult?.rid, "RID-NEWER")
    }

    private func openResult() async throws {
        let result = try saved.result("naomgs-A")
        let hits = ["sample-A", "sample-B"].flatMap { sample in (1...2).map { Self.hit(sample: sample, read: $0) } }
        let database = try NaoMgsDatabase.create(at: result.appendingPathComponent("hits.sqlite"), hits: hits)
        let manifest = NaoMgsManifest(
            sampleName: "sample-A", sourceFilePath: "/tmp/naomgs.tsv", hitCount: hits.count,
            taxonCount: 1, topTaxon: "Taxon", topTaxonId: 1_000
        )
        vc = NaoMgsResultViewController()
        isolateLayouts(vc)
        vc.testDisableMiniBAMLoading = true
        _ = vc.view
        vc.configure(database: database, manifest: manifest, bundleURL: result)
        let loaded = await waitUntil { self.vc.testDisplayedTaxonOrder.count == 2 }
        XCTAssertTrue(loaded, "the rows load")
    }

    private func select(sample: String, taxId: Int) throws {
        let row = try XCTUnwrap(vc.testDisplayedTaxonOrder.firstIndex { $0.contains(sample) && $0.hasSuffix(":\(taxId)") })
        vc.testTaxonomyTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private static func hit(sample: String, read: Int) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample, seqId: "\(sample)-read-\(read)", taxId: 1_000,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100,
            refStart: read * 100, refEnd: read * 100 + 100,
            readSequence: String(repeating: "A", count: 100), readQuality: String(repeating: "I", count: 100),
            subjectSeqId: "NC_000001.1", subjectTitle: "Taxon",
            bitScore: 210, eValue: 1e-40, percentIdentity: 99, editDistance: 1, fragmentLength: 100,
            isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
    }
}
