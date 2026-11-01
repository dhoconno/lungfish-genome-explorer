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

    /// The real rows of OC43's species and of a sibling species, as EsViritu files them and as `nodes.dmp` holds them.
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
