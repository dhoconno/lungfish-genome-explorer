// NCBITaxonomyLineagePhraseLeakTests.swift - The species clade and names a BLAST claim is judged by, read from a dump
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLAST of the S1 sweep, row BLAST-NAME-PHRASE-LEAK with BLAST-CATCHALL-SPECIES and BLAST-LINEAGE-PATH-NAMES. Every
// test writes a fixture in a temporary directory, never the installed taxonomy. The rows are the real rows of the NCBI
// dump of 2026-10-09 cut to each chain, except 400001 and 400002, which are fixture rows the dump does not hold.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

final class NCBITaxonomyLineagePhraseLeakTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestTempDirectory.make(prefix: "ncbi-taxonomy-phrase-leak")
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

    /// OC43 below the species Betacoronavirus gravedinis, whose path name Betacoronavirus 1 a rodent species holds.
    private static let betacorona: [(id: Int, parent: Int, rank: String, name: String)] = [
        (694002, 1, "genus", "Betacoronavirus"),
        (3433757, 694002, "species", "Betacoronavirus gravedinis"),
        (694003, 3433757, "no rank", "Betacoronavirus 1"),
        (31631, 694003, "no rank", "Human coronavirus OC43"),
        (2877475, 694002, "species", "Longquan Niviventer niviventer betacoronavirus 1"),
    ]

    /// HSV-1 with no strain 17 (10299), as a dump older than the strain's tax ID would hold it.
    private static let simplex: [(id: Int, parent: Int, rank: String, name: String)] = [
        (10294, 1, "genus", "Simplexvirus"),
        (3050292, 10294, "species", "Simplexvirus humanalpha1"),
        (10298, 3050292, "no rank", "Human alphaherpesvirus 1"),
    ]

    /// Item 1: a hit whose tax ID the dump holds in another species is outside, though its organism holds the row's
    /// name (Hepatitis B virus) or a path name (Betacoronavirus 1) as a whole phrase. A strain the dump lacks still
    /// supports by the row's own name.
    func testAnotherSpeciesThatHoldsTheRowOrAPathNameIsOutsideAndAStrainTheDumpLacksStillSupports() throws {
        try writeTaxonomy(Self.root + Self.hepadna + Self.betacorona + Self.simplex)

        let hbv = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 10407, names: ["Hepatitis B virus"], taxonomyDirectory: directory)
        )
        XCTAssertEqual(hbv.cladeTaxIds, [3431302, 10407, 10408])
        XCTAssertEqual(hbv.cladeNames, [], "Woolly monkey hepatitis B virus holds the row's name, so the name judges nothing")
        XCTAssertEqual(relation("Woolly monkey hepatitis B virus", 68416, claim: "Hepatitis B virus", hbv), .outside)
        XCTAssertEqual(relation("Hepatitis B virus subtype adw2", 10408, claim: "Hepatitis B virus", hbv), .clade)

        let oc43 = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 31631, names: ["Human coronavirus OC43"], taxonomyDirectory: directory)
        )
        XCTAssertEqual(oc43.cladeTaxIds, [3433757, 694003, 31631])
        XCTAssertEqual(oc43.cladeNames, ["Human coronavirus OC43"], "no path name judges")
        XCTAssertEqual(
            relation("Longquan Niviventer niviventer betacoronavirus 1", 2877475, claim: "Human coronavirus OC43", oc43), .outside
        )

        let hsv1 = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 10298, names: ["Human alphaherpesvirus 1"], taxonomyDirectory: directory)
        )
        XCTAssertEqual(hsv1.cladeNames, ["Human alphaherpesvirus 1"])
        XCTAssertEqual(relation("Human alphaherpesvirus 1 strain 17", 10299, claim: "Human alphaherpesvirus 1", hsv1), .clade)
    }

    /// Item 2: a catch-all species ("Human rhinovirus sp.", 169066) files records whose species nobody named, so it
    /// roots no clade. A claim under it is its own clade, and a claim on it keeps none of its children.
    func testACatchAllSpeciesBringsNoUnrelatedChildIntoTheClade() throws {
        try writeTaxonomy(Self.root + [
            (12059, 1, "genus", "Enterovirus"),
            (90010, 12059, "no rank", "unclassified Enterovirus"),
            (169066, 90010, "species", "Human rhinovirus sp."),
            (379525, 169066, "no rank", "Human rhinovirus UC"),
            (400_001, 169066, "no rank", "Human rhinovirus QPM"),
            (12060, 12059, "species", "Enterovirus A"),
            (12061, 12060, "no rank", "Enterovirus A71"),
        ])

        let child = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 379525, names: ["Human rhinovirus UC"], taxonomyDirectory: directory)
        )
        XCTAssertEqual(child.cladeTaxIds, [379525])
        XCTAssertEqual(relation("Human rhinovirus QPM", 400_001, claim: "Human rhinovirus UC", child), .outside)
        XCTAssertEqual(relation("Human rhinovirus sp.", 169066, claim: "Human rhinovirus UC", child), .outside)

        let catchAll = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 169066, names: ["Human rhinovirus sp."], taxonomyDirectory: directory)
        )
        XCTAssertEqual(catchAll.cladeTaxIds, [169066])
        XCTAssertEqual(relation("Human rhinovirus UC", 379525, claim: "Human rhinovirus sp.", catchAll), .outside)

        let clade = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 379525, taxonomyDirectory: directory))
        XCTAssertEqual(clade.root, 379525)
        XCTAssertEqual(clade.path, [379525])
        XCTAssertEqual(
            NCBITaxonomyLineage.speciesClade(of: 12061, taxonomyDirectory: directory)?.taxIds, [12060, 12061],
            "a named species keeps every descendant"
        )
    }

    /// A guard, green before and after: a species with more descendants than the request lists (Influenza A in the real
    /// dump) keeps its path names, since only names can judge the strains it leaves out.
    func testASpeciesTooLargeToListKeepsItsPathNamesForItsStrains() throws {
        try writeTaxonomy(Self.root + [
            (197911, 1, "genus", "Alphainfluenzavirus"),
            (2955291, 197911, "species", "Alphainfluenzavirus influenzae"),
            (11320, 2955291, "no rank", "Influenza A virus"),
            (114727, 11320, "serotype", "H1N1 subtype"),
            (641809, 114727, "no rank", "Influenza A virus (A/California/07/2009(H1N1))"),
            (400_002, 11320, "no rank", "Influenza A virus (A/Texas/50/2012(H3N2))"),
            (1522430, 1, "species", "synthetic Influenza A virus"),
        ])
        let name = "Influenza A virus (A/California/07/2009(H1N1))"

        let context = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 641809, names: [name], taxonomyDirectory: directory, limit: 2)
        )
        XCTAssertEqual(context.cladeTaxIds, [641809, 114727, 11320, 2955291])
        XCTAssertTrue(context.cladeNames.contains("Influenza A virus"))
        XCTAssertEqual(relation("Influenza A virus (A/Texas/50/2012(H3N2))", 400_002, claim: name, context), .clade)
    }
}
