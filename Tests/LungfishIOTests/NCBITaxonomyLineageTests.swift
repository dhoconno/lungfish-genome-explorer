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
}
