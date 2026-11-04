// TaxonTreeBlastTaxonomyTests.swift - Clade and genus relatives for BLAST verification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishIO

final class TaxonTreeBlastTaxonomyTests: XCTestCase {

    /// Herpesviruses as a Kraken 2 report lists them: HSV-1 and HSV-2 under
    /// Simplexvirus, EBV under Lymphocryptovirus.
    private let report = """
      0.00\t0\t0\tU\t0\tunclassified
    100.00\t1000\t0\tR\t1\troot
    100.00\t1000\t0\tD\t10239\t  Viruses
     95.00\t950\t0\tF\t3044472\t    Orthoherpesviridae
     85.00\t850\t10\tG\t10294\t      Simplexvirus
     79.00\t790\t0\tS\t3050292\t        Simplexvirus humanalpha1
     79.00\t790\t790\tS1\t10298\t          Human alphaherpesvirus 1
      5.00\t50\t0\tS\t3050293\t        Simplexvirus humanalpha2
      5.00\t50\t50\tS1\t10310\t          Human alphaherpesvirus 2
     10.00\t100\t0\tG\t10375\t      Lymphocryptovirus
     10.00\t100\t100\tS\t10376\t        Human gammaherpesvirus 4

    """

    func testSpeciesContextHasItsCladeAndGenusRelatives() throws {
        let tree = try KreportParser.parse(text: report)
        let context = tree.blastTaxonomyContext(for: 3050292)

        XCTAssertEqual(context.cladeTaxIds, [3050292, 10298])
        XCTAssertEqual(context.cladeNames, ["Human alphaherpesvirus 1", "Simplexvirus humanalpha1"])
        XCTAssertEqual(context.relatedTaxIds, [10294, 3050293, 10310])
        XCTAssertEqual(context.relatedNames.first, "Simplexvirus", "the genus name leads")
        XCTAssertFalse(context.relatedTaxIds.contains(10376), "EBV is in another genus")

        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human alphaherpesvirus 2", hitTaxId: 10310,
                queriedTaxonName: "Simplexvirus humanalpha1", context: context
            ),
            .relative
        )
        XCTAssertEqual(
            BlastTaxonMatching.relation(
                hitOrganism: "Human gammaherpesvirus 4", hitTaxId: 10376,
                queriedTaxonName: "Simplexvirus humanalpha1", context: context
            ),
            .outside
        )
    }

    func testGenusSelectionPutsHSV2InsideTheClade() throws {
        let tree = try KreportParser.parse(text: report)
        let context = tree.blastTaxonomyContext(for: 10294)
        XCTAssertTrue(context.cladeTaxIds.isSuperset(of: [10294, 3050292, 10298, 3050293, 10310]))
        XCTAssertTrue(context.relatedTaxIds.isEmpty, "a genus has no genus relatives")
    }

    func testTaxonMissingFromTheTreeIsItsOwnClade() throws {
        let tree = try KreportParser.parse(text: report)
        XCTAssertEqual(tree.blastTaxonomyContext(for: 562).cladeTaxIds, [562])
    }

    /// BLAST-ESVIRITU-FIRST-WORD. The classifier's own tree gave the clade, so the context says `species`, and a taxon the
    /// tree does not hold is judged by its own tax ID.
    func testTheContextSaysWhatItWasJudgedAt() throws {
        let tree = try KreportParser.parse(text: report)
        XCTAssertEqual(tree.blastTaxonomyContext(for: 3050292).basis, .species)
        XCTAssertEqual(tree.blastTaxonomyContext(for: 10294).basis, .species)
        XCTAssertEqual(tree.blastTaxonomyContext(for: 562).basis, .rowTaxId)
    }

    /// Rotavirus as a Kraken 2 report lists it: the binomial species 3432193, then 28875 and its host label 10941 as the
    /// no-rank nodes a report codes S1 and S2 (`TaxonomicRank.intermediate`), and a second genus member that stays a relative.
    private let rotavirusReport = """
      0.00\t0\t0\tU\t0\tunclassified
    100.00\t100\t0\tR\t1\troot
    100.00\t100\t0\tD\t10239\t  Viruses
    100.00\t100\t5\tG\t10912\t    Rotavirus
     90.00\t90\t5\tS\t3432193\t      Rotavirus alphagastroenteritidis
     85.00\t85\t25\tS1\t28875\t        Rotavirus A
     50.00\t50\t50\tS2\t10941\t          Human rotavirus A
     10.00\t10\t10\tS2\t42567\t          Rotavirus G9
      5.00\t5\t5\tS\t28876\t      Rotavirus B

    """

    /// BIO-BLAST-CLADE Q3 (lane BLAST-LINEAGE). A claim below a species is judged at its species, so the parent 28875
    /// and a sibling are the same organism, not relatives whose verified reads contradict the claim.
    func testCladeOfASubSpeciesNodeStartsAtItsSpecies() throws {
        let tree = try KreportParser.parse(text: rotavirusReport)

        let context = tree.blastTaxonomyContext(for: 10941)

        XCTAssertEqual(context.cladeTaxIds, [3432193, 28875, 10941, 42567])
        XCTAssertEqual(
            context.cladeNames,
            ["Human rotavirus A", "Rotavirus A", "Rotavirus G9", "Rotavirus alphagastroenteritidis"]
        )
        XCTAssertFalse(context.relatedTaxIds.contains(28875), "the parent is inside the claim's species")
        XCTAssertEqual(context.relatedTaxIds, [10912, 28876], "the genus and its other species stay relatives")
        XCTAssertEqual(context.relatedNames.first, "Rotavirus", "the genus name leads")

        XCTAssertEqual(
            tree.blastTaxonomyContext(for: 28875).cladeTaxIds, [3432193, 28875, 10941, 42567],
            "the no-rank parent's claim has the same species"
        )
        XCTAssertEqual(
            tree.blastTaxonomyContext(for: 3432193).cladeTaxIds, [3432193, 28875, 10941, 42567],
            "a species claim is its own root"
        )
    }
}
