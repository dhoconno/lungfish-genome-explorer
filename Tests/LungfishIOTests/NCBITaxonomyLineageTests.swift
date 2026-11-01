// NCBITaxonomyLineageTests.swift - The species clade a BLAST claim is judged at, read from a local nodes.dmp
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLAST-LINEAGE, BIO-BLAST-CLADE Q2 item 1. Every test reads a fixture in a temporary directory, never the
// installed taxonomy. The fixture holds the real rows for these IDs, cut to the chain.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

final class NCBITaxonomyLineageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestTempDirectory.make(prefix: "ncbi-taxonomy-lineage")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(directory)
    }

    /// Writes the fixture's `nodes.dmp` and `names.dmp` into `directory`, for the routes' tests in this target.
    static func writeRotavirusTaxonomy(to directory: URL) throws {
        let nodes = rotavirusNodes.map { "\($0.id)\t|\t\($0.parent)\t|\t\($0.rank)\t|\t\t|\t8\t|\n" }
        try nodes.joined().write(to: directory.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)
        let names: [(id: Int, name: String)] = [
            (10912, "Rotavirus"), (10941, "Human rotavirus A"), (28875, "Rotavirus A"), (42567, "Rotavirus G9"),
            (3432193, "Rotavirus alphagastroenteritidis"),
        ]
        let lines = names.map { "\($0.id)\t|\t\($0.name)\t|\t\t|\tscientific name\t|\n" }
        try lines.joined().write(to: directory.appendingPathComponent("names.dmp"), atomically: true, encoding: .utf8)
    }

    private func writeNodes(_ rows: [(id: Int, parent: Int, rank: String)]) throws {
        let lines = rows.map { "\($0.id)\t|\t\($0.parent)\t|\t\($0.rank)\t|\t\t|\t8\t|\t0\t|\t1\t|\t0\t|\t0\t|\t1\t|\t0\t|\t0\t|\t\t|\n" }
        try lines.joined().write(to: directory.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)
    }

    private func writeNames(_ rows: [(id: Int, name: String)]) throws {
        let lines = rows.map { "\($0.id)\t|\t\($0.name)\t|\t\t|\tscientific name\t|\n" }
        try lines.joined().write(to: directory.appendingPathComponent("names.dmp"), atomically: true, encoding: .utf8)
    }

    private static let rotavirusNodes: [(id: Int, parent: Int, rank: String)] = [
        (1, 1, "no rank"),
        (10912, 1, "genus"),
        (3432193, 10912, "species"),
        (28875, 3432193, "no rank"),
        (10941, 28875, "no rank"),
        (42567, 28875, "no rank"),
        (9606, 1, "species"),
    ]

    func testSpeciesCladeOfASubSpeciesTaxonIsItsSpeciesAndEveryDescendant() throws {
        try writeNodes(Self.rotavirusNodes)

        let clade = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 10941, taxonomyDirectory: directory))
        XCTAssertEqual(clade.root, 3432193)
        XCTAssertEqual(clade.path, [10941, 28875, 3432193], "the taxon first, up to the root")
        XCTAssertEqual(clade.taxIds, [3432193, 28875, 10941, 42567])

        let parent = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 28875, taxonomyDirectory: directory))
        XCTAssertEqual(parent.root, 3432193)
        XCTAssertEqual(parent.taxIds, [3432193, 28875, 10941, 42567])

        let genus = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 10912, taxonomyDirectory: directory))
        XCTAssertEqual(genus.root, 10912, "a genus has no species above it, so it is its own root")
        XCTAssertEqual(genus.path, [10912])
        XCTAssertEqual(genus.taxIds, [10912, 3432193, 28875, 10941, 42567])

        let species = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 3432193, taxonomyDirectory: directory))
        XCTAssertEqual(species.root, 3432193, "a species is its own root")
        XCTAssertEqual(species.path, [3432193])
        XCTAssertEqual(species.taxIds, [3432193, 28875, 10941, 42567])

        let capped = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 10941, taxonomyDirectory: directory, limit: 2))
        XCTAssertEqual(capped.taxIds, [10941, 28875, 3432193], "over the limit keeps the path only")
        XCTAssertEqual(capped.root, 3432193)

        let exactly = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 10941, taxonomyDirectory: directory, limit: 3))
        XCTAssertEqual(exactly.taxIds, [3432193, 28875, 10941, 42567], "the root's three descendants fit a limit of 3")
    }

    func testAMissingFileAnUnknownTaxIdAndANonPositiveTaxIdGiveNoClade() throws {
        XCTAssertNil(NCBITaxonomyLineage.speciesClade(of: 10941, taxonomyDirectory: directory), "no nodes.dmp is no lineage")
        XCTAssertNil(
            NCBITaxonomyLineage.speciesClade(of: 10941, taxonomyDirectory: directory.appendingPathComponent("absent")),
            "no directory is no lineage"
        )

        try writeNodes(Self.rotavirusNodes)
        XCTAssertNil(NCBITaxonomyLineage.speciesClade(of: 999_999, taxonomyDirectory: directory), "an unknown tax ID")
        XCTAssertNil(NCBITaxonomyLineage.speciesClade(of: 0, taxonomyDirectory: directory))
        XCTAssertNil(NCBITaxonomyLineage.speciesClade(of: -1, taxonomyDirectory: directory))
    }

    func testATaxonWithNoSpeciesAboveItIsItsOwnRoot() throws {
        // An "unclassified X" row hangs under a genus with no species between them.
        try writeNodes([(1, 1, "no rank"), (10912, 1, "genus"), (2000, 10912, "no rank"), (2001, 2000, "no rank")])

        let clade = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 2000, taxonomyDirectory: directory))
        XCTAssertEqual(clade.root, 2000)
        XCTAssertEqual(clade.path, [2000])
        XCTAssertEqual(clade.taxIds, [2000, 2001])
    }

    func testBrokenLinesAndAParentLoopNeverHangOrThrow() throws {
        let lines = "not a row\n\n7\t|\tseven\t|\tno rank\t|\n"
            + "100\t|\t101\t|\tno rank\t|\n101\t|\t100\t|\tno rank\t|\n"
            + "200\t|\t1\t|\tspecies\t|\n201\t|\t200\t|\tno rank\t|"
        try lines.write(to: directory.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)

        XCTAssertNil(NCBITaxonomyLineage.speciesClade(of: 7, taxonomyDirectory: directory), "a row without a numeric parent")
        let looped = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 100, taxonomyDirectory: directory))
        XCTAssertEqual(looped.root, 100, "a loop holds no species, so the taxon is its own root")
        XCTAssertEqual(looped.path, [100])
        let lastLine = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 201, taxonomyDirectory: directory))
        XCTAssertEqual(lastLine.root, 200, "a last line with no newline still reads")
        XCTAssertEqual(lastLine.taxIds, [200, 201])
    }

    /// `nodes.dmp` no longer lists a merged ID, so `merged.dmp` names the ID it became (BIO-BLAST-WALK Q2 item 2). The rows
    /// are the real ones of an ID EsViritu's table files an accession under.
    func testSpeciesCladeFollowsAMergedTaxId() throws {
        try writeNodes([(3430681, 10509, "species"), (2301506, 3430681, "no rank")])

        XCTAssertNil(
            NCBITaxonomyLineage.speciesClade(of: 3043422, taxonomyDirectory: directory),
            "with no merged.dmp the old ID is unknown"
        )

        try "3043422\t|\t2301506\t|\n7\t|\t8\t|\n"
            .write(to: directory.appendingPathComponent("merged.dmp"), atomically: true, encoding: .utf8)

        let clade = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 3043422, taxonomyDirectory: directory))
        XCTAssertEqual(clade.root, 3430681)
        XCTAssertEqual(clade.path, [2301506, 3430681], "the path starts at the ID the old one became")
        XCTAssertEqual(clade.taxIds, [2301506, 3430681])
        XCTAssertNil(
            NCBITaxonomyLineage.speciesClade(of: 7, taxonomyDirectory: directory),
            "a merged row whose new ID nodes.dmp does not hold is no lineage"
        )
    }

    // MARK: - The context a BLAST route judges by

    func testTheBlastContextHoldsTheCladeAndTheNamesUpToTheSpecies() throws {
        try writeNodes(Self.rotavirusNodes)
        try writeNames([
            (3432193, "Rotavirus alphagastroenteritidis"), (28875, "Rotavirus A"), (10941, "Human rotavirus A"),
            (42567, "Rotavirus G9"), (10912, "Rotavirus"),
        ])

        let context = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 10941, names: ["Human rotavirus A"], taxonomyDirectory: directory)
        )

        XCTAssertEqual(context.cladeTaxIds, [3432193, 28875, 10941, 42567])
        XCTAssertEqual(
            context.cladeNames, ["Human rotavirus A", "Rotavirus A", "Rotavirus alphagastroenteritidis"],
            "the row's own names lead, then the path's names, and a sibling or the genus adds no name"
        )
        XCTAssertTrue(context.relatedTaxIds.isEmpty)
        XCTAssertTrue(context.relatedNames.isEmpty)
    }

    func testTheBlastContextIsNilWithNoLineageAndKeepsTheRowsNamesWithNoNamesFile() throws {
        XCTAssertNil(NCBITaxonomyLineage.blastTaxonomyContext(of: 10941, names: ["Human rotavirus A"], taxonomyDirectory: nil))
        XCTAssertNil(NCBITaxonomyLineage.blastTaxonomyContext(of: 10941, names: ["Human rotavirus A"], taxonomyDirectory: directory))

        try writeNodes(Self.rotavirusNodes)
        XCTAssertNil(NCBITaxonomyLineage.blastTaxonomyContext(of: 0, names: ["No tax ID"], taxonomyDirectory: directory))
        let noNames = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 10941, names: ["Human rotavirus A"], taxonomyDirectory: directory)
        )
        XCTAssertEqual(noNames.cladeTaxIds, [3432193, 28875, 10941, 42567], "the IDs do not need names.dmp")
        XCTAssertEqual(noNames.cladeNames, ["Human rotavirus A"])
    }

    // MARK: - Empty, cut and odd-shaped dumps (BLAST-LINEAGE SWIFT SF1)

    func testAnEmptyOrTruncatedNodesFileGivesNilOrAPartialCladeAndNeverCrashes() throws {
        let nodesURL = directory.appendingPathComponent("nodes.dmp")

        try Data().write(to: nodesURL)
        XCTAssertNil(NCBITaxonomyLineage.speciesClade(of: 10941, taxonomyDirectory: directory), "an empty nodes.dmp holds no tax ID")

        // The species row is cut inside its rank, so it reads as no species and none sits above the taxon.
        let cutRank = "1\t|\t1\t|\tno rank\t|\n10912\t|\t1\t|\tgenus\t|\n28875\t|\t3432193\t|\tno rank\t|\n"
            + "10941\t|\t28875\t|\tno rank\t|\n3432193\t|\t10912\t|\tspec"
        try cutRank.write(to: nodesURL, atomically: true, encoding: .utf8)
        let partial = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 10941, taxonomyDirectory: directory))
        XCTAssertEqual(partial.root, 10941)
        XCTAssertEqual(partial.path, [10941])
        XCTAssertEqual(partial.taxIds, [10941])

        // The last row ends right after its first separator, so it is skipped and the row before it still reads.
        try "1\t|\t1\t|\tno rank\t|\n28875\t|\t".write(to: nodesURL, atomically: true, encoding: .utf8)
        XCTAssertNil(NCBITaxonomyLineage.speciesClade(of: 28875, taxonomyDirectory: directory), "a row with no parent is skipped")
        XCTAssertNotNil(NCBITaxonomyLineage.speciesClade(of: 1, taxonomyDirectory: directory))
    }

    func testANamesFileOfOtherShapesKeepsTheRowsNamesAndNeverCrashes() throws {
        try writeNodes(Self.rotavirusNodes)
        let namesURL = directory.appendingPathComponent("names.dmp")
        let shapes = [
            "28875\t|\tRotavirus A",
            "28875\t|\tRotavirus A\t|\t\t|\tauthority\t|",
            "3432193\t|\tRotavirus alphagastroenteritidis\t|\t\t|\tscientific na",
        ]
        func context() throws -> BlastTaxonomyContext {
            try XCTUnwrap(
                NCBITaxonomyLineage.blastTaxonomyContext(of: 10941, names: ["Human rotavirus A"], taxonomyDirectory: directory)
            )
        }

        // A row with no tail, an authority row and a row cut inside "scientific name" add no name, and the file has no final newline.
        try shapes.joined(separator: "\n").write(to: namesURL, atomically: true, encoding: .utf8)
        let odd = try context()
        XCTAssertEqual(odd.cladeNames, ["Human rotavirus A"])
        XCTAssertEqual(odd.cladeTaxIds, [3432193, 28875, 10941, 42567])

        // A real scientific-name row ahead of them adds its name.
        let real = "28875\t|\tRotavirus A\t|\t\t|\tscientific name\t|"
        try ([real] + shapes).joined(separator: "\n").write(to: namesURL, atomically: true, encoding: .utf8)
        let withReal = try context()
        XCTAssertEqual(withReal.cladeNames, ["Human rotavirus A", "Rotavirus A"])

        // An empty names.dmp keeps the row's own name.
        try Data().write(to: namesURL)
        let empty = try context()
        XCTAssertEqual(empty.cladeNames, ["Human rotavirus A"])
    }

    // MARK: - The path names against TaxonomyNameResolver (BLAST-LINEAGE BIO SF1)

    func testThePathNamesAreScientificNamesAndMatchResolveFromFile() throws {
        try writeNodes(Self.rotavirusNodes)
        // An acronym, a row at 288750 that shares the digits of 28875 and a genbank acronym sit among the scientific
        // names, and the last row has no newline.
        let lines = [
            "28875\t|\tRVA\t|\t\t|\tacronym\t|",
            "288750\t|\tRotavirus Z\t|\t\t|\tscientific name\t|",
            "28875\t|\tRotavirus A\t|\t\t|\tscientific name\t|",
            "10941\t|\tHuman rotavirus A\t|\t\t|\tscientific name\t|",
            "10941\t|\tHRV-A\t|\t\t|\tgenbank acronym\t|",
            "3432193\t|\tRotavirus alphagastroenteritidis\t|\t\t|\tscientific name\t|",
        ]
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("names.dmp"), atomically: true, encoding: .utf8)

        let context = try XCTUnwrap(
            NCBITaxonomyLineage.blastTaxonomyContext(of: 10941, names: ["Human rotavirus A"], taxonomyDirectory: directory)
        )
        XCTAssertEqual(context.cladeNames, ["Human rotavirus A", "Rotavirus A", "Rotavirus alphagastroenteritidis"])

        let resolved = try TaxonomyNameResolver.resolveFromFile(directory, taxIds: [10941, 28875, 3432193])
        XCTAssertEqual(
            resolved, [10941: "Human rotavirus A", 28875: "Rotavirus A", 3432193: "Rotavirus alphagastroenteritidis"],
            "the scan reads the names that the resolver reads"
        )
    }

    // MARK: - A row at an implausible tax ID (BLAST-LINEAGE SWIFT SF2)

    func testARowAtAnImplausibleTaxIdIsSkippedAndNeverSizesTheTable() throws {
        // 20,000,000 is past 1 << 24, about six times the largest real tax ID, so one such row must not grow the four
        // arrays of a read.
        var rows = Self.rotavirusNodes
        rows.append((20_000_000, 1, "species"))
        try writeNodes(rows)

        XCTAssertNil(
            NCBITaxonomyLineage.speciesClade(of: 20_000_000, taxonomyDirectory: directory), "a tax ID past the cap reads nil"
        )
        let clade = try XCTUnwrap(NCBITaxonomyLineage.speciesClade(of: 10941, taxonomyDirectory: directory))
        XCTAssertEqual(clade.root, 3432193)
        XCTAssertEqual(clade.taxIds, [3432193, 28875, 10941, 42567])
    }
}
