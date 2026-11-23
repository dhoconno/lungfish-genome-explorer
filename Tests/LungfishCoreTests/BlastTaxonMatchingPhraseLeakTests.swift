// BlastTaxonMatchingPhraseLeakTests.swift - A record of another species never supports a row by name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLAST of the S1 sweep, row BLAST-NAME-PHRASE-LEAK with BLAST-NAOMGS-TAXID-ZERO. These are the rule's halves,
// judged as the `blast submit` leaf judges them, from the accepted IDs and names alone. The halves that build the
// clade from a taxonomy dump are in `Tests/LungfishIOTests/NCBITaxonomyLineagePhraseLeakTests.swift`. Tax IDs and
// organism names are the real rows of the NCBI dump of 2026-10-09.

import XCTest
@testable import LungfishCore

final class BlastTaxonMatchingPhraseLeakTests: XCTestCase {

    private func hit(_ organism: String, taxId: Int?, accession: String) -> BlastHit {
        BlastHit(
            accession: accession,
            title: "\(organism), complete genome",
            organism: organism,
            taxId: taxId,
            hsps: [BlastHSP(bitScore: 140, evalue: 1e-30, identity: 76, alignLength: 76, queryFrom: 1, queryTo: 76)]
        )
    }

    /// Item 1. Hepatitis B virus (10407) under the species Orthohepadnavirus hominoidei (3431302). The dump files
    /// Woolly monkey hepatitis B virus (68416) under Orthohepadnavirus lagothricis, so the clade builder hands no name
    /// that it holds, and the leaf must not add the row's own name back. Before the fix the row's name came back and
    /// the record counted as the clade.
    func testARecordOfAnotherSpeciesThatHoldsTheRowNameIsOutside() {
        let hbvClade: Set<Int> = [3431302, 10407, 10408]
        let context = BlastTaxonomyContext(cladeTaxIds: hbvClade, cladeNames: [], basis: .species)
        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Woolly monkey hepatitis B virus", hitTaxId: 68416,
                queriedTaxonName: "Hepatitis B virus", context: context
            ),
            .outside
        )

        let results = BlastService().assignVerdicts(
            searchResults: [
                BlastSearchResult(queryId: "r1", queryLength: 76, hits: [hit("Woolly monkey hepatitis B virus", taxId: 68416, accession: "AF046996.1")])
            ],
            eValueThreshold: 1e-10,
            queriedTaxonName: "Hepatitis B virus",
            acceptedTaxIds: hbvClade,
            acceptedTaxonNames: []
        )
        XCTAssertEqual(results[0].verdict, .verified)
        XCTAssertFalse(results[0].matchesQueriedTaxon, "a record of another species does not support the row")
        XCTAssertEqual(results[0].topHitRelation, .outside)

        // The case the name rule exists for: a strain tax ID the tree lacks (HSV-1 strain 17 beside a report that lists
        // only the species and 10298) still supports by the clade's own name.
        let hsv1 = BlastTaxonomyContext(cladeTaxIds: [3050292, 10298], cladeNames: ["Human alphaherpesvirus 1"], basis: .species)
        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human alphaherpesvirus 1 strain 17", hitTaxId: 10299,
                queriedTaxonName: "Human alphaherpesvirus 1", context: hsv1
            ),
            .clade
        )
        // The queried name still marks a numbered sibling as a relative, which is never support.
        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human alphaherpesvirus 2", hitTaxId: 10310,
                queriedTaxonName: "Human alphaherpesvirus 1",
                context: BlastTaxonomyContext(cladeTaxIds: [3050292, 10298], basis: .species)
            ),
            .relative
        )
    }

    /// Item 3 (BLAST-NAOMGS-TAXID-ZERO). A NAO-MGS row with tax ID 0 sends no accepted tax ID and its own name, so the
    /// name rule judges it. Rotavirus C (36427, Rotavirus tritogastroenteritidis) shares only the first word with
    /// Rotavirus A and never supports it.
    func testRotavirusCNeverSupportsRotavirusAOnARowWithNoTaxId() {
        let results = BlastService().assignVerdicts(
            searchResults: [
                BlastSearchResult(queryId: "r1", queryLength: 76, hits: [hit("Rotavirus C", taxId: 36427, accession: "MK935457.1")]),
                BlastSearchResult(queryId: "r2", queryLength: 76, hits: [hit("Rotavirus C", taxId: nil, accession: "MK935458.1")]),
            ],
            eValueThreshold: 1e-10,
            queriedTaxonName: "Rotavirus A",
            acceptedTaxIds: [],
            acceptedTaxonNames: ["Rotavirus A"]
        )
        for row in results {
            XCTAssertFalse(row.matchesQueriedTaxon, "\(row.id): Rotavirus C does not support Rotavirus A")
            XCTAssertNotEqual(row.verdict, .verified, "\(row.id): a first-word match counts neither way")
        }
        let summary = BlastVerificationResult(
            taxonName: "Rotavirus A", taxId: 0, readResults: results,
            submittedAt: Date(), completedAt: Date(), rid: "R", blastProgram: "blastn", database: "core_nt"
        )
        XCTAssertEqual(summary.supportingCount, 0)
        XCTAssertEqual(summary.contradictingCount, 0)
    }
}
