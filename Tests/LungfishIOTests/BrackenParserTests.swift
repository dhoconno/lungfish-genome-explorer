// BrackenParserTests.swift - Tests for Bracken abundance estimation parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class BrackenParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseSimpleBrackenOutput() throws {
        let text = """
        name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads
        Escherichia coli\t562\tS\t200\t1800\t2000\t0.40000
        Staphylococcus aureus\t1280\tS\t150\t350\t500\t0.10000
        """

        let rows = try BrackenParser.parse(text: text)

        XCTAssertEqual(rows.count, 2)

        XCTAssertEqual(rows[0].name, "Escherichia coli")
        XCTAssertEqual(rows[0].taxId, 562)
        XCTAssertEqual(rows[0].taxonomyLevel, "S")
        XCTAssertEqual(rows[0].krakenAssignedReads, 200)
        XCTAssertEqual(rows[0].addedReads, 1800)
        XCTAssertEqual(rows[0].newEstReads, 2000)
        XCTAssertEqual(rows[0].fractionTotalReads, 0.40000, accuracy: 0.00001)

        XCTAssertEqual(rows[1].name, "Staphylococcus aureus")
        XCTAssertEqual(rows[1].taxId, 1280)
        XCTAssertEqual(rows[1].newEstReads, 500)
        XCTAssertEqual(rows[1].fractionTotalReads, 0.10000, accuracy: 0.00001)
    }

    func testParseWithoutHeader() throws {
        // Some Bracken outputs might not have a header
        let text = """
        Escherichia coli\t562\tS\t200\t1800\t2000\t0.40000
        """

        let rows = try BrackenParser.parse(text: text)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Escherichia coli")
    }

    func testParseEmptyFileThrows() {
        XCTAssertThrowsError(try BrackenParser.parse(text: "")) { error in
            XCTAssertTrue(error is BrackenParserError)
            if let brackenError = error as? BrackenParserError {
                switch brackenError {
                case .emptyFile:
                    break // Expected
                default:
                    XCTFail("Expected emptyFile error, got \(brackenError)")
                }
            }
        }
    }

    func testParseOnlyHeaderThrows() {
        let text = "name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads\n"

        XCTAssertThrowsError(try BrackenParser.parse(text: text)) { error in
            XCTAssertTrue(error is BrackenParserError)
        }
    }

    func testParseMalformedLineSkipped() throws {
        let text = """
        name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads
        Escherichia coli\t562\tS\t200\t1800\t2000\t0.40000
        this is not valid
        Pseudomonas aeruginosa\t287\tS\t100\t50\t150\t0.03000
        """

        let rows = try BrackenParser.parse(text: text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "Escherichia coli")
        XCTAssertEqual(rows[1].name, "Pseudomonas aeruginosa")
    }

    // MARK: - Merging into TaxonTree

    func testBrackenMerge() throws {
        // First, build a tree from kreport
        let kreportText = """
          1.00\t100\t100\tU\t0\tunclassified
         99.00\t9900\t100\tR\t1\troot
         90.00\t9000\t200\tD\t2\t  Bacteria
         50.00\t5000\t500\tS\t562\t    Escherichia coli
         30.00\t3000\t300\tS\t287\t    Pseudomonas aeruginosa
        """

        var tree = try KreportParser.parse(text: kreportText)

        // Then merge Bracken output
        let brackenText = """
        name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads
        Escherichia coli\t562\tS\t500\t2500\t3000\t0.30000
        Pseudomonas aeruginosa\t287\tS\t300\t700\t1000\t0.10000
        """

        let rows = try BrackenParser.parse(text: brackenText)
        BrackenParser.mergeBracken(rows: rows, into: &tree)

        // Verify Bracken values were set
        let ecoli = tree.node(taxId: 562)
        XCTAssertNotNil(ecoli)
        XCTAssertEqual(ecoli?.brackenReads, 3000)
        let ecoliFraction = try XCTUnwrap(ecoli?.brackenFraction)
        XCTAssertEqual(ecoliFraction, 0.30000, accuracy: 0.00001)

        let pseudo = tree.node(taxId: 287)
        XCTAssertNotNil(pseudo)
        XCTAssertEqual(pseudo?.brackenReads, 1000)
        let pseudoFraction = try XCTUnwrap(pseudo?.brackenFraction)
        XCTAssertEqual(pseudoFraction, 0.10000, accuracy: 0.00001)

        // Root should NOT have Bracken values
        XCTAssertNil(tree.root.brackenReads)
        XCTAssertNil(tree.root.brackenFraction)
    }

    func testBrackenMergeUnknownTaxidIgnored() throws {
        let kreportText = """
        100.00\t10000\t100\tR\t1\troot
         50.00\t5000\t5000\tS\t562\t  Escherichia coli
        """

        var tree = try KreportParser.parse(text: kreportText)

        // Bracken row with unknown taxId
        let brackenText = """
        name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads
        Escherichia coli\t562\tS\t500\t2500\t3000\t0.30000
        Unknown Species\t99999\tS\t100\t50\t150\t0.01500
        """

        let rows = try BrackenParser.parse(text: brackenText)
        BrackenParser.mergeBracken(rows: rows, into: &tree)

        // E. coli should have Bracken values
        XCTAssertEqual(tree.node(taxId: 562)?.brackenReads, 3000)

        // Unknown taxId should not appear in tree
        XCTAssertNil(tree.node(taxId: 99999))
    }

    func testBrackenNodesWithoutBrackenDataRemainNil() throws {
        let kreportText = """
        100.00\t10000\t100\tR\t1\troot
         60.00\t6000\t200\tD\t2\t  Bacteria
         50.00\t5000\t5000\tS\t562\t    Escherichia coli
          8.00\t800\t800\tS\t287\t    Pseudomonas aeruginosa
        """

        var tree = try KreportParser.parse(text: kreportText)

        // Only merge for E. coli
        let brackenText = """
        name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads
        Escherichia coli\t562\tS\t500\t2500\t3000\t0.30000
        """

        let rows = try BrackenParser.parse(text: brackenText)
        BrackenParser.mergeBracken(rows: rows, into: &tree)

        // E. coli has values
        XCTAssertNotNil(tree.node(taxId: 562)?.brackenReads)

        // Pseudomonas does NOT
        XCTAssertNil(tree.node(taxId: 287)?.brackenReads)
        XCTAssertNil(tree.node(taxId: 287)?.brackenFraction)

        // Bacteria (non-species) does NOT
        XCTAssertNil(tree.node(taxId: 2)?.brackenReads)
    }

    // MARK: - Real-World Fixture

    func testParseRealWorldBracken() throws {
        guard let url = Bundle.module.url(
            forResource: "sample",
            withExtension: "bracken",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find sample.bracken test fixture")
            return
        }

        let rows = try BrackenParser.parse(url: url)

        XCTAssertEqual(rows.count, 7)

        // Verify E. coli row
        let ecoli = rows.first { $0.taxId == 562 }
        XCTAssertNotNil(ecoli)
        XCTAssertEqual(ecoli?.name, "Escherichia coli")
        XCTAssertEqual(ecoli?.krakenAssignedReads, 500)
        XCTAssertEqual(ecoli?.addedReads, 3200)
        XCTAssertEqual(ecoli?.newEstReads, 3700)
        let ecoliFraction = try XCTUnwrap(ecoli?.fractionTotalReads)
        XCTAssertEqual(ecoliFraction, 0.37000, accuracy: 0.00001)
    }

    func testMergeFixtureIntoTree() throws {
        guard let kreportURL = Bundle.module.url(
            forResource: "sample",
            withExtension: "kreport",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find sample.kreport test fixture")
            return
        }

        guard let brackenURL = Bundle.module.url(
            forResource: "sample",
            withExtension: "bracken",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find sample.bracken test fixture")
            return
        }

        var tree = try KreportParser.parse(url: kreportURL)
        try BrackenParser.mergeBracken(url: brackenURL, into: &tree)

        // All 7 species from bracken should have been merged
        let speciesWithBracken = tree.nodes(at: .species).filter { $0.brackenReads != nil }
        XCTAssertEqual(speciesWithBracken.count, 7)

        // E. coli should have updated Bracken reads
        let ecoli = tree.node(taxId: 562)
        XCTAssertEqual(ecoli?.brackenReads, 3700)
        let ecoliFraction = try XCTUnwrap(ecoli?.brackenFraction)
        XCTAssertEqual(ecoliFraction, 0.37000, accuracy: 0.00001)

        // Non-species nodes should NOT have Bracken values
        XCTAssertNil(tree.root.brackenReads)
        XCTAssertNil(tree.node(taxId: 2)?.brackenReads) // Bacteria
    }

    // MARK: - Error Messages

    func testBrackenErrorDescriptions() {
        let emptyErr = BrackenParserError.emptyFile
        XCTAssertNotNil(emptyErr.errorDescription)
        XCTAssertTrue(emptyErr.errorDescription!.contains("Empty"))

        let fileErr = BrackenParserError.fileReadError(
            URL(fileURLWithPath: "/tmp/test.bracken"),
            "No such file"
        )
        XCTAssertNotNil(fileErr.errorDescription)
        XCTAssertTrue(fileErr.errorDescription!.contains("test.bracken"))
    }
}
