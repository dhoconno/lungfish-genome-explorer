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
}
