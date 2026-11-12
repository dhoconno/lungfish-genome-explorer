// BlastSavedRowOtherRouteProbeTests.swift - A FASTA search kept under a result folder shows on no other route's row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session probe PROBES-B, row BLAST-SAVED-ROW-LINEAGE-MATCHES-OTHER-ROUTE. A FASTA list's search records the file
// it came from and no sample, taxon or contig, so a source that fell back to a result folder gives the lineage (folder,
// nil, nil, nil). Its own row adds the IDs and bases picked. A row of another route in that folder is decided by the
// lineage alone when it holds no query sequences, so the question is which route builds a row with a nil sample, contig and
// taxon. The lookup below is the one `SavedBlastSearchRestorer` and `ClassifierResultActions` run. No network, no process.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class BlastSavedRowOtherRouteProbeTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var folder: URL!
    private let picked = [
        BlastSavedSearchRow.QuerySequence(id: "seq_a", sequence: "ACGTACGTAC"),
        BlastSavedSearchRow.QuerySequence(id: "seq_b", sequence: "GGCCGGCCGG"),
    ]

    override func setUpWithError() throws {
        saved = try SavedBlastSearchProject()
        folder = try saved.result("taxtriage-run")
        try saved.saveRecord(
            rid: "RID-FASTA", sourceResult: "taxtriage-run", sample: nil, taxId: nil, contig: nil,
            querySequences: picked.map { (id: $0.id, sequence: $0.sequence) }
        )
    }

    override func tearDownWithError() throws {
        saved?.remove()
    }

    /// Whether the saved search shows on `row`, as the restorer's look-up decides it.
    private func shows(on row: BlastSavedSearchRow) -> Bool {
        let found = BlastVerificationArchive.newestSearch(in: saved.project) { lineage, url in
            row.isSource(of: lineage, recordAt: url)
        }
        if case .saved = found { return true }
        return false
    }

    func testTheFASTAListsOwnRowShowsItsSearchAndNoOtherPick() throws {
        let own = try XCTUnwrap(BlastSavedSearchRow.fastaSelection(sequences: picked, sourceURL: folder))
        XCTAssertTrue(shows(on: own), "the list's own row")
        let reordered = try XCTUnwrap(BlastSavedSearchRow.fastaSelection(sequences: picked.reversed(), sourceURL: folder))
        XCTAssertTrue(shows(on: reordered), "the same picks in another order")
        let part = try XCTUnwrap(BlastSavedSearchRow.fastaSelection(sequences: [picked[0]], sourceURL: folder))
        XCTAssertFalse(shows(on: part), "a part of what was sent")
        let other = try XCTUnwrap(BlastSavedSearchRow.fastaSelection(
            sequences: [.init(id: "seq_a", sequence: "TTTTTTTTTT"), picked[1]], sourceURL: folder
        ))
        XCTAssertFalse(shows(on: other), "the same IDs with other bases")
    }

    /// Of the five builders of a row key, only TaxTriage's can leave the sample, the taxon and the contig all nil: its
    /// organism takes the sample from the BAM held now and the taxon from the report, and its contig is the accessions
    /// found for the row. EsViritu, NAO-MGS and NVD keys take a sample that is a non-optional `String`.
    func testNoRowOfAnotherRouteInTheFolderShowsTheFASTASearch() throws {
        let bare = TaxTriageOrganism(name: "Unplaced organism", score: 0, reads: 1, coverage: nil, taxId: nil, rank: nil, sample: nil)
        let taxTriage = bare.blastSavedSearchRow(accessions: [], sourceResultURL: folder)
        XCTAssertNil(taxTriage.sample)
        XCTAssertNil(taxTriage.taxId)
        XCTAssertNil(taxTriage.contig)
        XCTAssertNil(taxTriage.querySequences, "the premise: the real TaxTriage builder yields a key with the lineage alone")
        // Measured at af54540c8, red at this line without the expectation: the look-up accepts the FASTA record on this row,
        // since a row with no query sequences is decided by the lineage alone and the record's lineage names nothing more.
        // The fix lane removes this expectation (S1, BACKLOG BLAST-SAVED-ROW-LINEAGE-MATCHES-OTHER-ROUTE).
        XCTExpectFailure("BLAST-SAVED-ROW-LINEAGE-MATCHES-OTHER-ROUTE: the FASTA search shows on the TaxTriage row") {
            XCTAssertFalse(shows(on: taxTriage), "a FASTA search shown on a TaxTriage row is a BLAST verdict on the wrong row")
        }
    }

    func testRowsOfOtherRoutesThatNameASampleOrATaxonOrAContigNeverShowTheFASTASearch() throws {
        let nao = NaoMgsTaxonSummaryRow(
            sample: "S1", taxId: 11_320, name: "Virus", hitCount: 1, uniqueReadCount: 1, avgIdentity: 99, avgBitScore: 50,
            avgEditDistance: 0, pcrDuplicateCount: 0, accessionCount: 1, topAccessions: ["NC_001"], bamPath: nil, bamIndexPath: nil
        )
        XCTAssertFalse(shows(on: nao.blastSavedSearchRow(sourceResultURL: folder)), "NAO-MGS")
        let bySample = TaxTriageOrganism(name: "O", score: 0, reads: 1, coverage: nil, taxId: nil, rank: nil, sample: "S1")
        XCTAssertFalse(shows(on: bySample.blastSavedSearchRow(accessions: [], sourceResultURL: folder)), "TaxTriage with a sample")
        let byTaxon = TaxTriageOrganism(name: "O", score: 0, reads: 1, coverage: nil, taxId: 11_320, rank: nil, sample: nil)
        XCTAssertFalse(shows(on: byTaxon.blastSavedSearchRow(accessions: [], sourceResultURL: folder)), "TaxTriage with a taxon")
        let byContig = TaxTriageOrganism(name: "O", score: 0, reads: 1, coverage: nil, taxId: nil, rank: nil, sample: nil)
        XCTAssertFalse(shows(on: byContig.blastSavedSearchRow(accessions: ["NC_001"], sourceResultURL: folder)), "TaxTriage with a contig")
    }
}
