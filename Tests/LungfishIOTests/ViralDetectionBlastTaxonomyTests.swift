// ViralDetectionBlastTaxonomyTests.swift - An EsViritu row judged at species level through its database's tax ID
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLAST-ESVIRITU-SPECIES, BIO-BLAST-WALK Q2. Every test reads a fixture in a temporary directory, never the installed
// databases. The fixture holds the real rows of the EsViritu table and the NCBI dumps, cut to these IDs.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

final class ViralDetectionBlastTaxonomyTests: XCTestCase {
    private var scratch: URL!
    private var database: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "esviritu-blast-taxonomy")
        database = scratch.appendingPathComponent("v3.2.4", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private static let tableHeader = "Accession\tdescription\tName\tSegment\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tLength\tTaxID\tAssembly\tAsm_length\n"
    private static let oc43Row = "NC_006213.1\tHuman coronavirus OC43 strain ATCC VR-759\tHuman coronavirus OC43\t\tk__Viruses\tp__Pisuviricota\tc__Pisoniviricetes\to__Nidovirales\tf__Coronaviridae\tg__Betacoronavirus\ts__Betacoronavirus 1\tt__Human coronavirus OC43\t30741\t31631\tGCF_003972325.1\t30741\n"
    private static let rhinovirusRow = "NC_001490.1\tRhinovirus B14, complete sequence\trhinovirus B14\t\tk__Viruses\tp__Pisuviricota\tc__Pisoniviricetes\to__Picornavirales\tf__Picornaviridae\tg__Enterovirus\ts__Rhinovirus B\tt__rhinovirus B14\t7212\t12131\tGCF_000861265.1\t7212\n"

    private func writeTable(_ text: String) throws {
        try text.write(
            to: database.appendingPathComponent("virus_pathogen_database.all_metadata.tsv"), atomically: true, encoding: .utf8
        )
    }

    /// A folder with OC43's chain: `nodes.dmp` up to the genus and the sibling species HKU1, and the scientific names the
    /// path holds. 3433757 is the species, 694003 its no-rank child, and OC43, Bovine and Canine coronavirus sit under that.
    private func writeTaxonomy() throws -> URL {
        let taxonomy = scratch.appendingPathComponent("ncbi-taxonomy", isDirectory: true)
        try FileManager.default.createDirectory(at: taxonomy, withIntermediateDirectories: true)
        let nodes: [(id: Int, parent: Int, rank: String)] = [
            (694002, 2501931, "genus"), (2509481, 694002, "subgenus"), (3433757, 2509481, "species"),
            (694003, 3433757, "no rank"), (31631, 694003, "no rank"), (11128, 694003, "no rank"), (215681, 694003, "no rank"),
            (3433758, 2509481, "species"), (290028, 3433758, "no rank"),
        ]
        try nodes.map { "\($0.id)\t|\t\($0.parent)\t|\t\($0.rank)\t|\t\t|\t9\t|\t1\t|\t1\t|\t1\t|\t0\t|\t1\t|\t1\t|\t0\t|\t\t|\n" }
            .joined().write(to: taxonomy.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)
        let names: [(id: Int, name: String)] = [
            (31631, "Human coronavirus OC43"), (694003, "Betacoronavirus 1"), (3433757, "Betacoronavirus gravedinis"),
        ]
        try names.map { "\($0.id)\t|\t\($0.name)\t|\t\t|\tscientific name\t|\n" }
            .joined().write(to: taxonomy.appendingPathComponent("names.dmp"), atomically: true, encoding: .utf8)
        return taxonomy
    }

    /// The walk's OC43 row, as EsViritu's result table writes it, with its rank prefixes.
    private func oc43Detection(subspecies: String? = "t__Human coronavirus OC43") -> ViralDetection {
        ViralDetection(
            sampleId: "SRR35517703", name: "Human coronavirus OC43", description: "Human coronavirus OC43 strain ATCC VR-759",
            length: 30_741, segment: nil, accession: "NC_006213.1", assembly: "GCF_003972325.1", assemblyLength: 30_741,
            kingdom: "k__Viruses", phylum: "p__Pisuviricota", tclass: "c__Pisoniviricetes", order: "o__Nidovirales",
            family: "f__Coronaviridae", genus: "g__Betacoronavirus", species: "s__Betacoronavirus 1", subspecies: subspecies,
            rpkmf: 10, readCount: 2, coveredBases: 100, meanCoverage: 1, avgReadIdentity: 99, pi: 0,
            filteredReadsInSample: 1_000_000
        )
    }

    /// EsViritu's database files the row's accession under 31631, whose species is 3433757, so the row takes that clade.
    func testOC43DetectionJudgesAtItsSpeciesThroughItsDatabaseTaxId() throws {
        try writeTable(Self.tableHeader + Self.oc43Row)
        let taxonomy = try writeTaxonomy()

        let context = oc43Detection().blastTaxonomyContext(databaseDirectory: database, taxonomyDirectory: taxonomy)

        XCTAssertEqual(context.cladeTaxIds, [3433757, 694003, 31631, 11128, 215681])
        XCTAssertEqual(context.cladeNames, ["Human coronavirus OC43", "Betacoronavirus 1", "Betacoronavirus gravedinis"])
        XCTAssertEqual(context.relatedNames, ["Betacoronavirus"])
    }

    /// The species check exists for a `[tax adj: …]` row, whose name is adjusted while its accession is the reference's.
    func testDatabaseTaxIdIsRefusedWhenTheTableFilesAnotherSpecies() throws {
        let taxId = { (accession: String, species: String?) in
            EsVirituDatabaseTaxonomy.taxId(accession: accession, species: species, databaseDirectory: self.database)
        }

        XCTAssertNil(taxId("NC_001490.1", "s__Rhinovirus B"), "a missing file gives nil")

        try writeTable(Self.tableHeader + Self.oc43Row + Self.rhinovirusRow)

        XCTAssertEqual(taxId("NC_001490.1", "s__Rhinovirus B"), 12131)
        XCTAssertNil(taxId("NC_001490.1", "s__Rhinovirus C"), "the table files this accession under another species")
        XCTAssertNil(taxId("NC_000000.1", "s__Rhinovirus B"), "an unknown accession")
        XCTAssertNil(taxId("NC_001490", "s__Rhinovirus B"), "an accession matches whole, version included")
        XCTAssertNil(taxId("NC_001490.1", nil), "a row with no species cannot claim a table row that has one")

        try writeTable("Accession\tspecies\tLength\nNC_001490.1\ts__Rhinovirus B\t7212\n")
        XCTAssertNil(taxId("NC_001490.1", "s__Rhinovirus B"), "a table with no TaxID column")
    }
}
