// AnnotationDatabaseTests.swift - Tests for AnnotationDatabase SQLite annotation storage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class AnnotationDatabaseTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationDatabaseTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Creates a temp BED file from tab-separated lines.
    /// Each line is an array of column values.
    private func createBEDFile(lines: [[String]], filename: String = "test.bed") throws -> URL {
        let url = tempDir.appendingPathComponent(filename)
        let content = lines.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a database from BED lines and opens it for reading.
    private func createAndOpenDB(lines: [[String]]) throws -> (AnnotationDatabase, Int) {
        let bedURL = try createBEDFile(lines: lines)
        let dbURL = tempDir.appendingPathComponent("annotations.db")
        let count = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let db = try AnnotationDatabase(url: dbURL)
        return (db, count)
    }

    // MARK: - BED14 Helper

    /// Creates a full BED14 line (12 standard + type + attributes).
    private func bed14(
        chrom: String, start: Int, end: Int, name: String,
        score: Int = 0, strand: String = "+",
        thickStart: Int? = nil, thickEnd: Int? = nil,
        rgb: String = "0,0,0", blockCount: Int = 1,
        blockSizes: String? = nil, blockStarts: String? = nil,
        type: String, attributes: String = ""
    ) -> [String] {
        let ts = thickStart ?? start
        let te = thickEnd ?? end
        let bs = blockSizes ?? "\(end - start),"
        let bst = blockStarts ?? "0,"
        return [
            chrom, "\(start)", "\(end)", name,
            "\(score)", strand, "\(ts)", "\(te)",
            rgb, "\(blockCount)", bs, bst,
            type, attributes
        ]
    }

    // MARK: - Tests: createFromBED with GenBank Types

    func testCreateFromBEDWithGenBankTypes() throws {
        // BED file with columns 13-14 containing various GenBank types
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 200, end: 400, name: "cdsA", type: "CDS"),
            bed14(chrom: "chr1", start: 600, end: 800, name: "matPepA", type: "mat_peptide"),
            bed14(chrom: "chr1", start: 900, end: 1100, name: "regA", type: "regulatory"),
            bed14(chrom: "chr1", start: 1200, end: 1300, name: "sigPepA", type: "sig_peptide"),
            bed14(chrom: "chr1", start: 1400, end: 1500, name: "transPepA", type: "transit_peptide"),
            bed14(chrom: "chr1", start: 1600, end: 1700, name: "ncRNAa", type: "ncRNA"),
            bed14(chrom: "chr1", start: 1800, end: 1900, name: "bindA", type: "misc_binding"),
            bed14(chrom: "chr1", start: 2000, end: 2100, name: "protBindA", type: "protein_bind"),
            bed14(chrom: "chr1", start: 2200, end: 2300, name: "stemA", type: "stem_loop"),
            bed14(chrom: "chr1", start: 2400, end: 2500, name: "primerBindA", type: "primer_bind"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)

        XCTAssertEqual(count, 11, "All 11 types should be indexed")
        XCTAssertEqual(db.totalCount(), 11)

        // Verify all types are present
        let types = Set(db.allTypes())
        XCTAssertTrue(types.contains("gene"))
        XCTAssertTrue(types.contains("CDS"))
        XCTAssertTrue(types.contains("mat_peptide"))
        XCTAssertTrue(types.contains("regulatory"))
        XCTAssertTrue(types.contains("sig_peptide"))
        XCTAssertTrue(types.contains("transit_peptide"))
        XCTAssertTrue(types.contains("ncRNA"))
        XCTAssertTrue(types.contains("misc_binding"))
        XCTAssertTrue(types.contains("protein_bind"))
        XCTAssertTrue(types.contains("stem_loop"))
        XCTAssertTrue(types.contains("primer_bind"))
    }

    func testCreateFromBEDExcludesExonAndIntron() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 150, end: 250, name: "exon1", type: "exon"),
            bed14(chrom: "chr1", start: 250, end: 350, name: "intron1", type: "intron"),
            bed14(chrom: "chr1", start: 350, end: 450, name: "exon2", type: "exon"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "utr5a", type: "5'UTR"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "utr3a", type: "3'UTR"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)

        // gene and UTRs should be indexed; exon and intron excluded
        XCTAssertEqual(count, 3, "gene + 5'UTR + 3'UTR should be indexed, not exon/intron")
        XCTAssertEqual(db.totalCount(), 3)

        let types = Set(db.allTypes())
        XCTAssertTrue(types.contains("gene"))
        XCTAssertTrue(types.contains("5'UTR"))
        XCTAssertTrue(types.contains("3'UTR"))
        XCTAssertFalse(types.contains("exon"))
        XCTAssertFalse(types.contains("intron"))
    }

    // MARK: - Tests: queryByRegion

    func testQueryByRegionBasic() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 600, end: 900, name: "geneB", type: "gene"),
            bed14(chrom: "chr1", start: 1000, end: 1500, name: "geneC", type: "CDS"),
            bed14(chrom: "chr2", start: 100, end: 500, name: "geneD", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        // Query region overlapping geneA and geneB on chr1
        let results = db.queryByRegion(chromosome: "chr1", start: 200, end: 800)
        XCTAssertEqual(results.count, 2, "Should find geneA and geneB")

        let names = Set(results.map(\.name))
        XCTAssertTrue(names.contains("geneA"), "geneA overlaps 200-800")
        XCTAssertTrue(names.contains("geneB"), "geneB overlaps 200-800")
    }

    func testQueryByRegionNoOverlap() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 600, end: 900, name: "geneB", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        // Query a gap region between the two genes
        let results = db.queryByRegion(chromosome: "chr1", start: 500, end: 600)
        XCTAssertEqual(results.count, 0, "No genes overlap the 500-600 gap")
    }

    func testQueryByRegionDifferentChromosome() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr2", start: 100, end: 500, name: "geneB", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        // Query chr1 should only return chr1 features
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "geneA")
    }

    func testQueryByRegionWithAttributes() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene",
                  attributes: "gene=BRCA1;db_xref=GeneID%3A672;description=breast%20cancer"),
            bed14(chrom: "chr1", start: 600, end: 900, name: "cdsA", type: "CDS",
                  attributes: "protein_id=NP_001234;product=BRCA1%20protein"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 2)

        // Check that attributes are populated
        let geneResult = results.first(where: { $0.name == "geneA" })
        XCTAssertNotNil(geneResult?.attributes)
        XCTAssertTrue(geneResult!.attributes!.contains("gene=BRCA1"))
        XCTAssertTrue(geneResult!.attributes!.contains("db_xref=GeneID%3A672"))

        let cdsResult = results.first(where: { $0.name == "cdsA" })
        XCTAssertNotNil(cdsResult?.attributes)
        XCTAssertTrue(cdsResult!.attributes!.contains("protein_id=NP_001234"))
    }

    func testQueryByRegionLimit() throws {
        // Create many features to test the limit parameter
        var lines: [[String]] = []
        for i in 0..<100 {
            lines.append(bed14(chrom: "chr1", start: i * 10, end: i * 10 + 5,
                              name: "gene\(i)", type: "gene"))
        }

        let (db, _) = try createAndOpenDB(lines: lines)

        // Query entire range but with a limit
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000, limit: 10)
        XCTAssertEqual(results.count, 10, "Should respect the limit parameter")
    }

    func testQueryByRegionReturnsDeterministicStartOrder() throws {
        // Insert deliberately out of order in BED input.
        let lines = [
            bed14(chrom: "chr1", start: 500, end: 700, name: "geneC", type: "gene"),
            bed14(chrom: "chr1", start: 100, end: 200, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 300, end: 450, name: "geneB", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000, limit: 3)

        XCTAssertEqual(results.map(\.name), ["geneA", "geneB", "geneC"],
                       "queryByRegion should return rows in ascending genomic order")
    }

    // MARK: - Tests: lookupAnnotation with Attributes

    func testLookupAnnotationWithAttributes() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene",
                  attributes: "gene=BRCA1;gene_biotype=protein_coding"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        let record = db.lookupAnnotation(name: "geneA", chromosome: "chr1", start: 100, end: 500)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.name, "geneA")
        XCTAssertEqual(record?.type, "gene")
        XCTAssertNotNil(record?.attributes)

        // Parse and verify attributes
        let parsed = AnnotationDatabase.parseAttributes(record!.attributes!)
        XCTAssertEqual(parsed["gene"], "BRCA1")
        XCTAssertEqual(parsed["gene_biotype"], "protein_coding")
    }

    func testLookupAnnotationNotFound() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        let record = db.lookupAnnotation(name: "nonexistent", chromosome: "chr1", start: 100, end: 500)
        XCTAssertNil(record)
    }

    // MARK: - Tests: allTypes with New Types

    func testAllTypesIncludesNewTypes() throws {
        let lines = [
            bed14(chrom: "chr1", start: 0, end: 100, name: "a", type: "gene"),
            bed14(chrom: "chr1", start: 100, end: 200, name: "b", type: "CDS"),
            bed14(chrom: "chr1", start: 200, end: 300, name: "c", type: "mat_peptide"),
            bed14(chrom: "chr1", start: 300, end: 400, name: "d", type: "regulatory"),
            bed14(chrom: "chr1", start: 400, end: 500, name: "e", type: "ncRNA"),
            bed14(chrom: "chr1", start: 500, end: 600, name: "f", type: "stem_loop"),
            bed14(chrom: "chr1", start: 600, end: 700, name: "g", type: "primer_bind"),
            bed14(chrom: "chr1", start: 700, end: 800, name: "h", type: "mRNA"),
            bed14(chrom: "chr1", start: 800, end: 900, name: "i", type: "promoter"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        let types = db.allTypes()
        XCTAssertTrue(types.contains("gene"))
        XCTAssertTrue(types.contains("CDS"))
        XCTAssertTrue(types.contains("mat_peptide"))
        XCTAssertTrue(types.contains("regulatory"))
        XCTAssertTrue(types.contains("ncRNA"))
        XCTAssertTrue(types.contains("stem_loop"))
        XCTAssertTrue(types.contains("primer_bind"))
        XCTAssertTrue(types.contains("mRNA"))
        XCTAssertTrue(types.contains("promoter"))
    }

    // MARK: - Tests: Deduplication

    func testCreateFromBEDDeduplicates() throws {
        // Same name+type+chrom+start+end → deduplicated
        // Same name+chrom+start+end but different type → both kept
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "CDS"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)

        // gene+gene deduplicates (same type), but gene+CDS are distinct
        XCTAssertEqual(count, 2, "Same name/coords but different types should both be kept")
        XCTAssertEqual(db.totalCount(), 2)
    }

    // MARK: - Tests: Edge Cases

    func testCreateFromBEDSkipsEmptyAndUnknownNames() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 600, end: 900, name: "", type: "gene"),
            bed14(chrom: "chr1", start: 1000, end: 1300, name: "unknown", type: "gene"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)

        XCTAssertEqual(count, 1, "Empty and 'unknown' names should be skipped")
        XCTAssertEqual(db.totalCount(), 1)
    }

    func testCreateFromBEDSkipsCommentsAndShortLines() throws {
        let bedURL = tempDir.appendingPathComponent("test.bed")
        let content = """
        # This is a comment
        chr1\t100\t500\tgeneA\t0\t+\t100\t500\t0,0,0\t1\t400,\t0,\tgene\t
        # Another comment
        chr1
        chr1\t100
        chr1\t200\t400\tgeneB\t0\t+\t200\t400\t0,0,0\t1\t200,\t0,\tgene\t
        """
        try content.write(to: bedURL, atomically: true, encoding: .utf8)

        let dbURL = tempDir.appendingPathComponent("annotations.db")
        let count = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)

        XCTAssertEqual(count, 2, "Should index 2 valid lines, skipping comments and short lines")
    }

    func testQueryByRegionBoundaryConditions() throws {
        // Feature at exactly [100, 500)
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        // Query exactly at the end boundary — should NOT overlap (end is exclusive)
        let atEnd = db.queryByRegion(chromosome: "chr1", start: 500, end: 600)
        XCTAssertEqual(atEnd.count, 0, "Query starting at feature end should not overlap")

        // Query ending exactly at feature start — should NOT overlap
        let atStart = db.queryByRegion(chromosome: "chr1", start: 0, end: 100)
        XCTAssertEqual(atStart.count, 0, "Query ending at feature start should not overlap")

        // Query with 1bp overlap at start
        let overlapStart = db.queryByRegion(chromosome: "chr1", start: 0, end: 101)
        XCTAssertEqual(overlapStart.count, 1, "Query overlapping by 1bp should match")

        // Query with 1bp overlap at end
        let overlapEnd = db.queryByRegion(chromosome: "chr1", start: 499, end: 600)
        XCTAssertEqual(overlapEnd.count, 1, "Query overlapping by 1bp at end should match")
    }

    func testParseAttributes() throws {
        // Test the static parseAttributes method
        let attrs = "gene=BRCA1;db_xref=GeneID%3A672;description=breast%20cancer%20susceptibility"
        let parsed = AnnotationDatabase.parseAttributes(attrs)

        XCTAssertEqual(parsed["gene"], "BRCA1")
        XCTAssertEqual(parsed["db_xref"], "GeneID:672", "URL-encoded colon should be decoded")
        XCTAssertEqual(parsed["description"], "breast cancer susceptibility", "URL-encoded spaces should be decoded")
    }

    func testParseAttributesEmptyAndMalformed() throws {
        // Empty string
        let empty = AnnotationDatabase.parseAttributes("")
        XCTAssertTrue(empty.isEmpty)

        // Malformed (no = sign)
        let malformed = AnnotationDatabase.parseAttributes("justAKey;anotherKey")
        XCTAssertTrue(malformed.isEmpty)

        // Mix of valid and invalid
        let mixed = AnnotationDatabase.parseAttributes("valid=yes;invalid;also_valid=true")
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed["valid"], "yes")
        XCTAssertEqual(mixed["also_valid"], "true")
    }

    // MARK: - Tests: Existing Types Still Work

    func testOriginalIndexableTypesStillWork() throws {
        // Verify all the original types that were already in the set still get indexed
        let originalTypes = [
            "gene", "mRNA", "transcript", "region", "promoter", "enhancer",
            "primer", "primer_pair", "amplicon", "SNP", "variation",
            "restriction_site", "repeat_region", "misc_feature",
            "silencer", "terminator", "polyA_signal",
        ]

        var lines: [[String]] = []
        for (i, type) in originalTypes.enumerated() {
            lines.append(bed14(chrom: "chr1", start: i * 100, end: i * 100 + 50,
                              name: "feat\(i)", type: type))
        }

        let (db, count) = try createAndOpenDB(lines: lines)

        XCTAssertEqual(count, originalTypes.count, "All original types should still be indexed")
        XCTAssertEqual(db.totalCount(), originalTypes.count)

        let types = Set(db.allTypes())
        for type in originalTypes {
            XCTAssertTrue(types.contains(type), "Original type '\(type)' should be in allTypes()")
        }
    }

    // MARK: - Tests: Deduplication Details

    func testCreateFromBEDDeduplicateFirstWins() throws {
        // Same name+type+chrom+start+end — deduplicates, first occurrence wins
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "feat1", type: "gene",
                  attributes: "product=first"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "feat1", type: "gene",
                  attributes: "product=second"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)
        XCTAssertEqual(count, 1)

        let record = db.lookupAnnotation(name: "feat1", chromosome: "chr1", start: 100, end: 500)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.type, "gene")
        // First occurrence's attributes should be stored
        XCTAssertTrue(record?.attributes?.contains("first") ?? false, "First occurrence should win")
    }

    // MARK: - Tests: BED Column Fallback

    func testCreateFromBEDWithoutColumn13DefaultsToGene() throws {
        // BED4 lines (no type column) — should default to "gene"
        let bedURL = tempDir.appendingPathComponent("test.bed")
        let content = """
        chr1\t100\t500\tgeneA\t0\t+
        chr1\t600\t900\tgeneB\t0\t-
        """
        try content.write(to: bedURL, atomically: true, encoding: .utf8)

        let dbURL = tempDir.appendingPathComponent("annotations.db")
        let count = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let db = try AnnotationDatabase(url: dbURL)

        XCTAssertEqual(count, 2)
        let types = db.allTypes()
        XCTAssertEqual(types, ["gene"], "Without column 13, type should default to 'gene'")
    }

    // MARK: - Tests: queryByRegion Edge Cases

    func testQueryByRegionDegenerateInterval() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        // Zero-width interval at a point inside the feature — still matches
        // SQL: end > 300 AND start < 300 → 500 > 300 AND 100 < 300 → true
        let zeroWidthInside = db.queryByRegion(chromosome: "chr1", start: 300, end: 300)
        XCTAssertEqual(zeroWidthInside.count, 1, "Zero-width query at contained point should match")

        // Zero-width interval outside the feature
        let zeroWidthOutside = db.queryByRegion(chromosome: "chr1", start: 600, end: 600)
        XCTAssertEqual(zeroWidthOutside.count, 0, "Zero-width query outside feature should not match")

        // Inverted interval (start > end) — no results
        let inverted = db.queryByRegion(chromosome: "chr1", start: 500, end: 100)
        XCTAssertEqual(inverted.count, 0, "Inverted interval should return no results")
    }

    func testQueryByRegionReturnsCorrectTypes() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", strand: "+", type: "gene"),
            bed14(chrom: "chr1", start: 200, end: 400, name: "cdsA", strand: "-", type: "CDS"),
            bed14(chrom: "chr1", start: 300, end: 800, name: "regA", strand: ".", type: "regulatory"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 3)

        let byName: [String: AnnotationDatabaseRecord] = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })
        XCTAssertEqual(byName["geneA"]?.type, "gene")
        XCTAssertEqual(byName["geneA"]?.strand, "+")
        XCTAssertEqual(byName["cdsA"]?.type, "CDS")
        XCTAssertEqual(byName["cdsA"]?.strand, "-")
        XCTAssertEqual(byName["regA"]?.type, "regulatory")
        XCTAssertEqual(byName["regA"]?.strand, ".")
    }
}
