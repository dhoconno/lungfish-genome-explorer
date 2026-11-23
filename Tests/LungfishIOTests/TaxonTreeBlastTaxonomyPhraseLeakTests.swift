// TaxonTreeBlastTaxonomyPhraseLeakTests.swift - The Kraken 2 clade a BLAST claim is judged by, with NCBI Taxonomy installed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Fix BLAST-FIX m1 of the S1 sweep, ruling BIO-BLAST items 1 to 3 (row BLAST-NAME-PHRASE-LEAK on the Kraken 2 route).
// Every test writes a fixture dump in a temporary directory, never the installed taxonomy. The dump rows are those of
// `NCBITaxonomyLineagePhraseLeakTests`, the real rows of the NCBI dump of 2026-10-09 cut to each chain.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

final class TaxonTreeBlastTaxonomyPhraseLeakTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestTempDirectory.make(prefix: "taxon-tree-phrase-leak")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(directory)
    }

    private func writeTaxonomy(_ rows: [(id: Int, parent: Int, rank: String, name: String)]) throws {
        let nodes = rows.map { "\($0.id)\t|\t\($0.parent)\t|\t\($0.rank)\t|\t\t|\t9\t|\n" }
        try nodes.joined().write(to: directory.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)
        let names = rows.map { "\($0.id)\t|\t\($0.name)\t|\t\t|\tscientific name\t|\n" }
        try names.joined().write(to: directory.appendingPathComponent("names.dmp"), atomically: true, encoding: .utf8)
    }

    private func relation(_ organism: String, _ taxId: Int, claim: String, _ context: BlastTaxonomyContext) -> BlastHitRelation? {
        BlastTaxonMatching.relation(hitOrganism: organism, hitTaxId: taxId, queriedTaxonName: claim, context: context)
    }

    private static let root: [(id: Int, parent: Int, rank: String, name: String)] = [(1, 1, "no rank", "root")]

    /// Hepatitis B virus and Woolly monkey hepatitis B virus: two species of the genus Orthohepadnavirus.
    private static let hepadna: [(id: Int, parent: Int, rank: String, name: String)] = [
        (10405, 1, "genus", "Orthohepadnavirus"),
        (3431302, 10405, "species", "Orthohepadnavirus hominoidei"),
        (10407, 3431302, "no rank", "Hepatitis B virus"),
        (10408, 10407, "no rank", "Hepatitis B virus subtype adw2"),
        (3431303, 10405, "species", "Orthohepadnavirus lagothricis"),
        (68416, 3431303, "no rank", "Woolly monkey hepatitis B virus"),
    ]

    /// HSV-1 with no strain 17 (10299), as a dump older than the strain's tax ID would hold it.
    private static let simplex: [(id: Int, parent: Int, rank: String, name: String)] = [
        (10294, 1, "genus", "Simplexvirus"),
        (3050292, 10294, "species", "Simplexvirus humanalpha1"),
        (10298, 3050292, "no rank", "Human alphaherpesvirus 1"),
    ]

    /// A Kraken 2 report whose HBV clade holds the species and the reported 10407, the row the user verifies.
    private let hepadnaReport = """
      0.00\t0\t0\tU\t0\tunclassified
    100.00\t100\t0\tR\t1\troot
    100.00\t100\t0\tD\t10239\t  Viruses
    100.00\t100\t0\tG\t10405\t    Orthohepadnavirus
    100.00\t100\t0\tS\t3431302\t      Orthohepadnavirus hominoidei
    100.00\t100\t100\tS1\t10407\t        Hepatitis B virus

    """

    /// A Kraken 2 report of HSV-1 at its species, its genus and the reported 10298.
    private let simplexReport = """
      0.00\t0\t0\tU\t0\tunclassified
    100.00\t100\t0\tR\t1\troot
    100.00\t100\t0\tD\t10239\t  Viruses
    100.00\t100\t0\tG\t10294\t    Simplexvirus
    100.00\t100\t0\tS\t3050292\t      Simplexvirus humanalpha1
    100.00\t100\t100\tS1\t10298\t        Human alphaherpesvirus 1

    """

    /// Item 3, red at `db59f0dc7`: with NCBI Taxonomy installed, a record the dump files in another species is outside,
    /// though its organism holds the name of a report taxon in the clade (Woolly monkey hepatitis B virus on a Hepatitis
    /// B virus row). The dump's own clade IDs join the report's, so a subtype the report does not list is in the clade.
    func testARecordOfAnotherSpeciesThatHoldsTheRowsNameIsOutsideWithNCBITaxonomyInstalled() throws {
        try writeTaxonomy(Self.root + Self.hepadna)
        let tree = try KreportParser.parse(text: hepadnaReport)

        let context = tree.blastTaxonomyContext(for: 10407, taxonomyDirectory: directory)

        XCTAssertEqual(relation("Woolly monkey hepatitis B virus", 68416, claim: "Hepatitis B virus", context), .outside)
        XCTAssertEqual(context.cladeTaxIds, [3431302, 10407, 10408], "the report's clade and the dump's")
        XCTAssertEqual(
            context.cladeNames, ["Orthohepadnavirus hominoidei"],
            "Woolly monkey hepatitis B virus holds Hepatitis B virus, so that name judges nothing"
        )
        XCTAssertEqual(context.relatedTaxIds, [10405], "the report's genus members outside the clade stay relatives")
        XCTAssertEqual(context.relatedNames, ["Orthohepadnavirus"])
        XCTAssertEqual(relation("Hepatitis B virus subtype adw2", 10408, claim: "Hepatitis B virus", context), .clade)
    }

    /// Item 3 guard, green before and after: a strain record whose tax ID the dump lacks still supports by the name of a
    /// report taxon that no taxon outside the clade holds.
    func testAStrainTheDumpLacksStillSupportsByTheReportsName() throws {
        try writeTaxonomy(Self.root + Self.simplex)
        let tree = try KreportParser.parse(text: simplexReport)

        let context = tree.blastTaxonomyContext(for: 10298, taxonomyDirectory: directory)

        XCTAssertEqual(
            relation("Human alphaherpesvirus 1 strain 17", 10299, claim: "Human alphaherpesvirus 1", context), .clade
        )
    }

    /// Item 3 guard, green before and after: with no NCBI Taxonomy, or a dump that does not hold the claim, the IDs,
    /// names and relatives are the report tree's alone, as at the base. The basis on the path with no NCBI Taxonomy is
    /// milestone m2's (UX-BLAST-NOTAX), so this test does not pin it.
    func testWithNoTaxonomyOrNoLineageTheContextIsTheReportTreesAlone() throws {
        let tree = try KreportParser.parse(text: hepadnaReport)

        for context in [tree.blastTaxonomyContext(for: 10407, taxonomyDirectory: nil), tree.blastTaxonomyContext(for: 10407)] {
            XCTAssertEqual(context.cladeTaxIds, [3431302, 10407])
            XCTAssertEqual(context.cladeNames, ["Hepatitis B virus", "Orthohepadnavirus hominoidei"])
            XCTAssertEqual(context.relatedTaxIds, [10405])
            XCTAssertEqual(context.relatedNames, ["Orthohepadnavirus"])
        }

        try writeTaxonomy(Self.root + Self.simplex)
        let noLineage = tree.blastTaxonomyContext(for: 10407, taxonomyDirectory: directory)
        XCTAssertEqual(noLineage.cladeTaxIds, [3431302, 10407], "the dump does not hold 10407")
        XCTAssertEqual(noLineage.cladeNames, ["Hepatitis B virus", "Orthohepadnavirus hominoidei"])
        XCTAssertEqual(noLineage.relatedTaxIds, [10405])
        XCTAssertEqual(noLineage.relatedNames, ["Orthohepadnavirus"])
    }
}
