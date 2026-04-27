// AnnotationDatabaseTests.swift - Tests for AnnotationDatabase SQLite annotation storage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishIO
@testable import LungfishCore

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

    func testCreateFromBEDIncludesExonAndIntron() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 150, end: 250, name: "exon1", type: "exon"),
            bed14(chrom: "chr1", start: 250, end: 350, name: "intron1", type: "intron"),
            bed14(chrom: "chr1", start: 350, end: 450, name: "exon2", type: "exon"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "utr5a", type: "5'UTR"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "utr3a", type: "3'UTR"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)

        XCTAssertEqual(count, 6, "All feature rows should be stored, including exon/intron")
        XCTAssertEqual(db.totalCount(), 6)

        let types = Set(db.allTypes())
        XCTAssertTrue(types.contains("gene"))
        XCTAssertTrue(types.contains("5'UTR"))
        XCTAssertTrue(types.contains("3'UTR"))
        XCTAssertTrue(types.contains("exon"))
        XCTAssertTrue(types.contains("intron"))
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

    func testOpenRejectsMissingSchemaMetadata() throws {
        let dbURL = tempDir.appendingPathComponent("bad_annotations.db")
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &rawDB), SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        XCTAssertNotNil(rawDB)
        XCTAssertEqual(sqlite3_exec(rawDB, """
            CREATE TABLE annotations (
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                chromosome TEXT NOT NULL,
                start INTEGER NOT NULL,
                end INTEGER NOT NULL,
                strand TEXT NOT NULL DEFAULT '.',
                attributes TEXT,
                block_count INTEGER,
                block_sizes TEXT,
                block_starts TEXT,
                gene_name TEXT
            );
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try AnnotationDatabase(url: dbURL)) { error in
            guard case AnnotationDatabaseError.invalidSchema(let message) = error else {
                return XCTFail("Expected invalidSchema error, got \(error)")
            }
            XCTAssertTrue(message.contains("db_metadata"))
        }
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

    // MARK: - Tests: Duplicate Preservation

    func testCreateFromBEDPreservesDuplicateRows() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "CDS"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)

        XCTAssertEqual(count, 3, "Input duplicates should be preserved in SQLite")
        XCTAssertEqual(db.totalCount(), 3)
    }

    // MARK: - Tests: Edge Cases

    func testCreateFromBEDIncludesUnknownAndSynthesizesEmptyName() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "geneA", type: "gene"),
            bed14(chrom: "chr1", start: 600, end: 900, name: "", type: "gene"),
            bed14(chrom: "chr1", start: 1000, end: 1300, name: "unknown", type: "gene"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)

        XCTAssertEqual(count, 3, "All rows should be stored")
        XCTAssertEqual(db.totalCount(), 3)
        let names = Set(db.queryByRegion(chromosome: "chr1", start: 0, end: 2000).map(\.name))
        XCTAssertTrue(names.contains("geneA"))
        XCTAssertTrue(names.contains("unknown"))
        XCTAssertTrue(names.contains("gene:chr1:600-900"), "Empty names should be synthesized")
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

    // MARK: - Tests: Duplicate Row Semantics

    func testCreateFromBEDPreservesDuplicateAttributesRows() throws {
        // Same name+type+chrom+start+end should preserve both rows.
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "feat1", type: "gene",
                  attributes: "product=first"),
            bed14(chrom: "chr1", start: 100, end: 500, name: "feat1", type: "gene",
                  attributes: "product=second"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)
        XCTAssertEqual(count, 2)

        let records = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
            .filter { $0.name == "feat1" }
        XCTAssertEqual(records.count, 2)
        let attrs = Set(records.compactMap(\.attributes))
        XCTAssertTrue(attrs.contains("product=first"))
        XCTAssertTrue(attrs.contains("product=second"))
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

    // MARK: - Tests: v3 Schema (Block Data)

    func testCreateFromBEDWithBlockData() throws {
        // BED12+2 with multi-block features (e.g., mRNA with 3 exons)
        let lines = [
            // mRNA with 3 exons: 100-200, 400-550, 700-900
            bed14(chrom: "chr1", start: 100, end: 900, name: "mRNA1", strand: "+",
                  blockCount: 3, blockSizes: "100,150,200,", blockStarts: "0,300,600,",
                  type: "mRNA", attributes: "gene=BRCA1"),
            // Single-block gene
            bed14(chrom: "chr1", start: 1000, end: 2000, name: "gene1", strand: "-",
                  type: "gene"),
        ]

        let (db, count) = try createAndOpenDB(lines: lines)
        XCTAssertEqual(count, 2)

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 3000)
        XCTAssertEqual(results.count, 2)

        let mRNA = results.first { $0.name == "mRNA1" }
        XCTAssertNotNil(mRNA)
        XCTAssertEqual(mRNA?.blockCount, 3)
        XCTAssertEqual(mRNA?.blockSizes, "100,150,200,")
        XCTAssertEqual(mRNA?.blockStarts, "0,300,600,")

        let gene = results.first { $0.name == "gene1" }
        XCTAssertNotNil(gene)
        XCTAssertEqual(gene?.blockCount, 1)
    }

    func testToAnnotationMultiInterval() throws {
        // Create a record with 3 blocks (multi-exon feature)
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 900, name: "XM_001234",
                  strand: "+", blockCount: 3,
                  blockSizes: "100,150,200,", blockStarts: "0,300,600,",
                  type: "mRNA", attributes: "gene=BRCA1;product=breast%20cancer"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 1)

        let annotation = results[0].toAnnotation()
        XCTAssertEqual(annotation.type, .mRNA)
        XCTAssertEqual(annotation.name, "XM_001234")
        XCTAssertEqual(annotation.chromosome, "chr1")
        XCTAssertEqual(annotation.strand, .forward)
        XCTAssertEqual(annotation.intervals.count, 3, "Should have 3 intervals from block data")

        // Verify interval positions: start + blockStart[i], size blockSize[i]
        XCTAssertEqual(annotation.intervals[0].start, 100)  // 100 + 0
        XCTAssertEqual(annotation.intervals[0].end, 200)    // 100 + 0 + 100
        XCTAssertEqual(annotation.intervals[1].start, 400)  // 100 + 300
        XCTAssertEqual(annotation.intervals[1].end, 550)    // 100 + 300 + 150
        XCTAssertEqual(annotation.intervals[2].start, 700)  // 100 + 600
        XCTAssertEqual(annotation.intervals[2].end, 900)    // 100 + 600 + 200

        // Verify qualifiers parsed from attributes
        XCTAssertEqual(annotation.qualifiers["gene"]?.values.first, "BRCA1")
        XCTAssertEqual(annotation.qualifiers["product"]?.values.first, "breast cancer")
    }

    func testToAnnotationSingleInterval() throws {
        // Single-block feature should produce single interval
        let lines = [
            bed14(chrom: "chr2", start: 500, end: 800, name: "geneX",
                  strand: "-", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)
        let results = db.queryByRegion(chromosome: "chr2", start: 0, end: 1000)
        XCTAssertEqual(results.count, 1)

        let annotation = results[0].toAnnotation()
        XCTAssertEqual(annotation.type, .gene)
        XCTAssertEqual(annotation.name, "geneX")
        XCTAssertEqual(annotation.strand, .reverse)
        XCTAssertEqual(annotation.intervals.count, 1)
        XCTAssertEqual(annotation.intervals[0].start, 500)
        XCTAssertEqual(annotation.intervals[0].end, 800)
    }

    func testToAnnotationStrandMapping() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 200, name: "fwd", strand: "+", type: "gene"),
            bed14(chrom: "chr1", start: 300, end: 400, name: "rev", strand: "-", type: "gene"),
            bed14(chrom: "chr1", start: 500, end: 600, name: "unk", strand: ".", type: "gene"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)

        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.toAnnotation()) })
        XCTAssertEqual(byName["fwd"]?.strand, .forward)
        XCTAssertEqual(byName["rev"]?.strand, .reverse)
        XCTAssertEqual(byName["unk"]?.strand, .unknown)
    }

    func testToAnnotationTypeMapping() throws {
        // Verify various type strings map to correct AnnotationType
        // Verify various type strings map to expected AnnotationType values.
        let lines = [
            bed14(chrom: "chr1", start: 0, end: 100, name: "a", type: "gene"),
            bed14(chrom: "chr1", start: 100, end: 200, name: "b", type: "mRNA"),
            bed14(chrom: "chr1", start: 200, end: 300, name: "c", type: "CDS"),
            bed14(chrom: "chr1", start: 300, end: 400, name: "d", type: "regulatory"),
            bed14(chrom: "chr1", start: 400, end: 500, name: "e", type: "promoter"),
            bed14(chrom: "chr1", start: 500, end: 600, name: "f", type: "region"),
        ]

        let (db, _) = try createAndOpenDB(lines: lines)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.toAnnotation()) })

        XCTAssertEqual(byName["a"]?.type, .gene)
        XCTAssertEqual(byName["b"]?.type, .mRNA)
        XCTAssertEqual(byName["c"]?.type, .cds)
        XCTAssertEqual(byName["d"]?.type, .regulatory)
        XCTAssertEqual(byName["e"]?.type, .promoter)
        XCTAssertEqual(byName["f"]?.type, .region)
    }

    // MARK: - GFF3 Helpers

    /// Creates a temp GFF3 file from lines.
    private func createGFF3File(lines: [String], filename: String = "test.gff3") throws -> URL {
        let url = tempDir.appendingPathComponent(filename)
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a database from GFF3 lines and opens it for reading.
    private func createAndOpenDBFromGFF3(
        lines: [String],
        chromosomeSizes: [(String, Int64)]? = nil
    ) async throws -> (AnnotationDatabase, Int) {
        let gffURL = try createGFF3File(lines: lines)
        let dbURL = tempDir.appendingPathComponent("annotations_gff3.db")
        let count = try await AnnotationDatabase.createFromGFF3(
            gffURL: gffURL, outputURL: dbURL, chromosomeSizes: chromosomeSizes
        )
        let db = try AnnotationDatabase(url: dbURL)
        return (db, count)
    }

    /// Builds a GFF3 feature line.
    private func gff3Line(
        seqid: String, source: String = "test", type: String,
        start: Int, end: Int, strand: String = "+",
        attributes: String
    ) -> String {
        "\(seqid)\t\(source)\t\(type)\t\(start)\t\(end)\t.\t\(strand)\t.\t\(attributes)"
    }

    // MARK: - Tests: createFromGFF3 Basic

    func testCreateFromGFF3BasicGene() async throws {
        let lines = [
            "##gff-version 3",
            gff3Line(seqid: "chr1", type: "gene", start: 1001, end: 2000, attributes: "ID=gene1;Name=TestGene"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)

        XCTAssertEqual(count, 1)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 3000)
        XCTAssertEqual(results.count, 1)
        let gene = results[0]
        XCTAssertEqual(gene.name, "TestGene")
        XCTAssertEqual(gene.type, "gene")
        // GFF3 1-based start=1001 → 0-based start=1000
        XCTAssertEqual(gene.start, 1000)
        // GFF3 end=2000 (inclusive) → 0-based exclusive end=2000
        XCTAssertEqual(gene.end, 2000)
    }

    func testCreateFromGFF3ParsesGeneiousQuotedAttributes() async throws {
        let lines = [
            "##gff-version 3",
            "##source-version geneious 2023.2.1",
            gff3Line(seqid: "M1", source: "Geneious", type: "gene", start: 263031, end: 291324, strand: "-",
                     attributes: #"gene_id "GABBR1"; gene_name "GABBR1""#),
            gff3Line(seqid: "M1", source: "Geneious", type: "transcript", start: 263031, end: 291324, strand: "-",
                     attributes: #"gene_id "GABBR1"; gene_name "GABBR1"; transcript_id "GABBR1"; transcript_name "GABBR1""#),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)

        XCTAssertEqual(count, 2)
        let results = db.queryByRegion(chromosome: "M1", start: 263000, end: 292000)
        let byType = Dictionary(uniqueKeysWithValues: results.map { ($0.type, $0) })

        XCTAssertEqual(byType["gene"]?.name, "GABBR1")
        XCTAssertEqual(byType["gene"]?.geneName, "GABBR1")
        XCTAssertEqual(byType["transcript"]?.name, "GABBR1")
        XCTAssertEqual(byType["transcript"]?.geneName, "GABBR1")

        let attrs = try XCTUnwrap(byType["transcript"]?.attributes)
        let parsed = AnnotationDatabase.parseAttributes(attrs)
        XCTAssertEqual(parsed["gene_id"], "GABBR1")
        XCTAssertEqual(parsed["gene_name"], "GABBR1")
        XCTAssertEqual(parsed["transcript_id"], "GABBR1")
        XCTAssertEqual(parsed["transcript_name"], "GABBR1")
    }

    func testCreateFromGFF3CoordinateConversion() async throws {
        // GFF3 is 1-based inclusive; SQLite stores 0-based half-open
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 1, end: 100, attributes: "ID=g1;Name=first"),
            gff3Line(seqid: "chr1", type: "gene", start: 500, end: 500, attributes: "ID=g2;Name=point"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 2)

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })

        // start=1 → 0, end=100 → 100
        XCTAssertEqual(byName["first"]?.start, 0)
        XCTAssertEqual(byName["first"]?.end, 100)
        // start=500 → 499, end=500 → 500 (1bp feature)
        XCTAssertEqual(byName["point"]?.start, 499)
        XCTAssertEqual(byName["point"]?.end, 500)
    }

    func testCreateFromGFF3FASTADirectiveStopsParsing() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 200, attributes: "ID=g1;Name=before"),
            "##FASTA",
            ">chr1",
            "ATCGATCGATCG",
            gff3Line(seqid: "chr1", type: "gene", start: 300, end: 400, attributes: "ID=g2;Name=after"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 1, "Only features before ##FASTA should be parsed")

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.first?.name, "before")
    }

    func testCreateFromGFF3SkipsExonAndIntron() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 500, attributes: "ID=g1;Name=myGene"),
            gff3Line(seqid: "chr1", type: "exon", start: 100, end: 200, attributes: "Parent=g1"),
            gff3Line(seqid: "chr1", type: "intron", start: 200, end: 300, attributes: "ID=intron1;Name=myIntron"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        // gene indexed, exon consumed as child, intron ignored by GFF3 importer
        XCTAssertEqual(count, 1)
        XCTAssertEqual(db.queryByRegion(chromosome: "chr1", start: 0, end: 1000).first?.name, "myGene")
    }

    func testCreateFromGFF3StrandHandling() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 500, strand: "+", attributes: "ID=g1;Name=forward"),
            gff3Line(seqid: "chr1", type: "gene", start: 600, end: 900, strand: "-", attributes: "ID=g2;Name=reverse"),
            gff3Line(seqid: "chr1", type: "gene", start: 1000, end: 1200, strand: ".", attributes: "ID=g3;Name=unknown"),
        ]
        let (db, _) = try await createAndOpenDBFromGFF3(lines: lines)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 2000)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })

        XCTAssertEqual(byName["forward"]?.strand, "+")
        XCTAssertEqual(byName["reverse"]?.strand, "-")
        XCTAssertEqual(byName["unknown"]?.strand, ".")
    }

    // MARK: - Tests: createFromGFF3 Parent-Child Aggregation

    func testCreateFromGFF3TranscriptWithExonBlocks() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "mRNA", start: 1000, end: 5000, strand: "+",
                     attributes: "ID=mrna1;Name=TestmRNA"),
            gff3Line(seqid: "chr1", type: "exon", start: 1000, end: 1500,
                     attributes: "Parent=mrna1"),
            gff3Line(seqid: "chr1", type: "exon", start: 2500, end: 3000,
                     attributes: "Parent=mrna1"),
            gff3Line(seqid: "chr1", type: "exon", start: 4000, end: 5000,
                     attributes: "Parent=mrna1"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        // mRNA indexed with blocks; exons consumed
        XCTAssertEqual(count, 1)

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 10000)
        XCTAssertEqual(results.count, 1)
        let mrna = results[0]
        XCTAssertEqual(mrna.name, "TestmRNA")

        // Check block data
        let annotation = mrna.toAnnotation()
        XCTAssertEqual(annotation.intervals.count, 3, "Should have 3 exon blocks")
    }

    func testCreateFromGFF3CDSFallbackWhenNoExons() async throws {
        // Transcript with CDS children but no exon children
        let lines = [
            gff3Line(seqid: "chr1", type: "mRNA", start: 1000, end: 5000,
                     attributes: "ID=mrna1;Name=CDSonly"),
            gff3Line(seqid: "chr1", type: "CDS", start: 1000, end: 1500,
                     attributes: "Parent=mrna1"),
            gff3Line(seqid: "chr1", type: "CDS", start: 3000, end: 4000,
                     attributes: "Parent=mrna1"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 3, "Transcript and CDS child features should both be indexed")

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 10000)
        XCTAssertEqual(results.count, 3)

        let byType = Dictionary(grouping: results, by: \.type)
        XCTAssertEqual(byType["mRNA"]?.count, 1)
        XCTAssertEqual(byType["CDS"]?.count, 2)

        let transcript = byType["mRNA"]!.first!.toAnnotation()
        XCTAssertEqual(transcript.intervals.count, 2, "Should use CDS intervals as fallback blocks")
    }

    func testCreateFromGFF3MultiParentExon() async throws {
        // Exon shared between two transcripts
        let lines = [
            gff3Line(seqid: "chr1", type: "mRNA", start: 1000, end: 3000,
                     attributes: "ID=mrna1;Name=transcript1"),
            gff3Line(seqid: "chr1", type: "mRNA", start: 1000, end: 4000,
                     attributes: "ID=mrna2;Name=transcript2"),
            // Shared exon
            gff3Line(seqid: "chr1", type: "exon", start: 1000, end: 1500,
                     attributes: "Parent=mrna1,mrna2"),
            // Each has a unique second exon
            gff3Line(seqid: "chr1", type: "exon", start: 2000, end: 3000,
                     attributes: "Parent=mrna1"),
            gff3Line(seqid: "chr1", type: "exon", start: 3000, end: 4000,
                     attributes: "Parent=mrna2"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 2, "Both transcripts should be indexed")

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 10000)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })

        // Both transcripts should have 2 blocks each (shared + unique exon)
        let t1 = byName["transcript1"]!.toAnnotation()
        let t2 = byName["transcript2"]!.toAnnotation()
        XCTAssertEqual(t1.intervals.count, 2)
        XCTAssertEqual(t2.intervals.count, 2)
    }

    // MARK: - Tests: createFromGFF3 Deduplication

    func testCreateFromGFF3Deduplication() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 500, attributes: "ID=g1;Name=dup"),
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 500, attributes: "ID=g2;Name=dup"),
        ]
        let (_, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 1, "Duplicate name|type|chrom|start|end should be deduplicated")
    }

    // MARK: - Tests: createFromGFF3 Chromosome Clipping

    func testCreateFromGFF3ChromosomeClipping() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 900, end: 1200,
                     attributes: "ID=g1;Name=overshoot"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(
            lines: lines,
            chromosomeSizes: [("chr1", 1000)]
        )
        XCTAssertEqual(count, 1)

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 2000)
        let gene = results[0]
        // end should be clipped to chromosome size (1000)
        XCTAssertEqual(gene.end, 1000)
        // start should remain at 899 (1-based 900 → 0-based 899)
        XCTAssertEqual(gene.start, 899)
    }

    // MARK: - Tests: createFromGFF3 Attribute Round-Trip

    func testCreateFromGFF3AttributeRoundTrip() async throws {
        // Test that attributes with special characters survive encoding/decoding
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 500,
                     attributes: "ID=g1;Name=myGene;product=ATP%3Bhydrolase;Note=a%3Db%3Bc"),
        ]
        let (db, _) = try await createAndOpenDBFromGFF3(lines: lines)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        let gene = results[0]

        let annotation = gene.toAnnotation()
        // product had %3B (semicolon) in GFF3 → decoded → re-encoded as %3B for storage
        // On round-trip via toAnnotation → qualifiers, should get "ATP;hydrolase"
        XCTAssertFalse(annotation.qualifiers.isEmpty)
        XCTAssertEqual(annotation.qualifiers["product"]?.firstValue, "ATP;hydrolase")
        XCTAssertEqual(annotation.qualifiers["Note"]?.firstValue, "a=b;c")
    }

    // MARK: - Tests: createFromGFF3 GFF3 Transcript Types

    func testCreateFromGFF3TranscriptTypes() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "lnc_RNA", start: 100, end: 500, attributes: "ID=t1;Name=lncRNA1"),
            gff3Line(seqid: "chr1", type: "rRNA", start: 600, end: 900, attributes: "ID=t2;Name=rRNA1"),
            gff3Line(seqid: "chr1", type: "tRNA", start: 1000, end: 1100, attributes: "ID=t3;Name=tRNA1"),
            gff3Line(seqid: "chr1", type: "miRNA", start: 1200, end: 1300, attributes: "ID=t4;Name=miRNA1"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 4, "All GFF3 transcript types should be indexed")

        let types = Set(db.allTypes())
        XCTAssertTrue(types.contains("lnc_RNA"))
        XCTAssertTrue(types.contains("rRNA"))
        XCTAssertTrue(types.contains("tRNA"))
        XCTAssertTrue(types.contains("miRNA"))
    }

    // MARK: - Tests: createFromGFF3 Empty/Malformed

    func testCreateFromGFF3EmptyFile() async throws {
        let lines: [String] = ["##gff-version 3", "# just a comment"]
        let (_, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 0)
    }

    func testCreateFromGFF3MalformedLines() async throws {
        let lines = [
            "this is not a valid GFF3 line",
            "chr1\ttest\tgene",  // Too few columns
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 500, attributes: "ID=g1;Name=valid"),
        ]
        let (_, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 1, "Only the valid line should be parsed")
    }

    // MARK: - Tests: CDS Merging by Same GFF3 ID

    func testCreateFromGFF3CDSMergedByID() async throws {
        // 5 CDS lines sharing the same ID=cds-XP_001 should merge into 1 multi-block entry
        let lines = [
            "##gff-version 3",
            gff3Line(seqid: "chr1", type: "gene", start: 1000, end: 6000, strand: "-",
                     attributes: "ID=gene-GZMB;Name=GZMB;gene=GZMB"),
            gff3Line(seqid: "chr1", type: "mRNA", start: 1000, end: 6000, strand: "-",
                     attributes: "ID=rna-XM_001;Parent=gene-GZMB;Name=XM_001;gene=GZMB"),
            gff3Line(seqid: "chr1", type: "exon", start: 1000, end: 1200, strand: "-",
                     attributes: "Parent=rna-XM_001"),
            gff3Line(seqid: "chr1", type: "exon", start: 2000, end: 2200, strand: "-",
                     attributes: "Parent=rna-XM_001"),
            gff3Line(seqid: "chr1", type: "exon", start: 3000, end: 3200, strand: "-",
                     attributes: "Parent=rna-XM_001"),
            gff3Line(seqid: "chr1", type: "exon", start: 4000, end: 4300, strand: "-",
                     attributes: "Parent=rna-XM_001"),
            gff3Line(seqid: "chr1", type: "exon", start: 5500, end: 6000, strand: "-",
                     attributes: "Parent=rna-XM_001"),
            // 5 CDS lines, ALL sharing ID=cds-XP_001
            gff3Line(seqid: "chr1", type: "CDS", start: 1050, end: 1200, strand: "-",
                     attributes: "ID=cds-XP_001;Parent=rna-XM_001;Name=XP_001;gene=GZMB"),
            gff3Line(seqid: "chr1", type: "CDS", start: 2000, end: 2148, strand: "-",
                     attributes: "ID=cds-XP_001;Parent=rna-XM_001;Name=XP_001;gene=GZMB"),
            gff3Line(seqid: "chr1", type: "CDS", start: 3000, end: 3136, strand: "-",
                     attributes: "ID=cds-XP_001;Parent=rna-XM_001;Name=XP_001;gene=GZMB"),
            gff3Line(seqid: "chr1", type: "CDS", start: 4000, end: 4261, strand: "-",
                     attributes: "ID=cds-XP_001;Parent=rna-XM_001;Name=XP_001;gene=GZMB"),
            gff3Line(seqid: "chr1", type: "CDS", start: 5500, end: 5644, strand: "-",
                     attributes: "ID=cds-XP_001;Parent=rna-XM_001;Name=XP_001;gene=GZMB"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)

        // Should have 3 records: gene, mRNA (with exon blocks), and ONE merged CDS
        XCTAssertEqual(count, 3, "5 CDS lines with same ID should merge into 1 row")

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 10000)
        let cdsResults = results.filter { $0.type == "CDS" }
        XCTAssertEqual(cdsResults.count, 1, "Should be exactly one merged CDS record")

        let cds = cdsResults[0]
        XCTAssertEqual(cds.name, "XP_001")
        XCTAssertEqual(cds.start, 1049)  // 1050 - 1 (GFF3 1-based → 0-based)
        XCTAssertEqual(cds.end, 5644)    // max end across all CDS intervals
        XCTAssertEqual(cds.blockCount, 5, "Should have 5 blocks from 5 CDS intervals")

        // Verify block data reconstructs correctly
        let annotation = cds.toAnnotation()
        XCTAssertEqual(annotation.intervals.count, 5, "Should have 5 intervals from merged CDS")
        XCTAssertEqual(annotation.strand, .reverse)

        // Verify interval positions (sorted by start, 0-based)
        XCTAssertEqual(annotation.intervals[0].start, 1049)
        XCTAssertEqual(annotation.intervals[0].end, 1200)
        XCTAssertEqual(annotation.intervals[1].start, 1999)
        XCTAssertEqual(annotation.intervals[1].end, 2148)
        XCTAssertEqual(annotation.intervals[4].start, 5499)
        XCTAssertEqual(annotation.intervals[4].end, 5644)
    }

    func testCreateFromGFF3SingleCDSNotMerged() async throws {
        // Single CDS (unique ID) should NOT trigger merging
        let lines = [
            gff3Line(seqid: "chr1", type: "CDS", start: 100, end: 300,
                     attributes: "ID=cds-single;Name=SingleCDS;gene=TestGene"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        XCTAssertEqual(count, 1)

        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 1)
        let cds = results[0]
        XCTAssertNil(cds.blockCount, "Single-interval CDS should not have block data")
    }

    func testCreateFromGFF3CDSWithoutIDNotMerged() async throws {
        // CDS features without ID attributes should be inserted individually
        let lines = [
            gff3Line(seqid: "chr1", type: "mRNA", start: 1000, end: 5000,
                     attributes: "ID=mrna1;Name=CDSonly"),
            gff3Line(seqid: "chr1", type: "CDS", start: 1000, end: 1500,
                     attributes: "Parent=mrna1;gene=TestGene"),
            gff3Line(seqid: "chr1", type: "CDS", start: 3000, end: 4000,
                     attributes: "Parent=mrna1;gene=TestGene"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)
        // mRNA (1) + 2 individual CDS (no shared ID) = 3
        XCTAssertEqual(count, 3)

        let cdsResults = db.queryByRegion(chromosome: "chr1", start: 0, end: 10000)
            .filter { $0.type == "CDS" }
        XCTAssertEqual(cdsResults.count, 2, "CDS without shared ID should remain separate")
    }

    // MARK: - Tests: Gene Name Search

    func testCreateFromGFF3GeneNameSearch() async throws {
        let lines = [
            "##gff-version 3",
            gff3Line(seqid: "chr1", type: "gene", start: 1000, end: 6000,
                     attributes: "ID=gene-GZMB;Name=GZMB;gene=GZMB"),
            gff3Line(seqid: "chr1", type: "mRNA", start: 1000, end: 6000,
                     attributes: "ID=rna-XM_001;Parent=gene-GZMB;Name=XM_001;gene=GZMB"),
            gff3Line(seqid: "chr1", type: "CDS", start: 1050, end: 1200,
                     attributes: "ID=cds-XP_001;Name=XP_001;gene=GZMB"),
        ]
        let (db, _) = try await createAndOpenDBFromGFF3(lines: lines)

        // Search for "GZMB" should find all three features (gene by name, mRNA+CDS by gene_name)
        let results = db.query(nameFilter: "GZMB")
        XCTAssertEqual(results.count, 3, "Searching GZMB should find gene + mRNA + CDS via gene_name")

        let types = Set(results.map(\.type))
        XCTAssertTrue(types.contains("gene"))
        XCTAssertTrue(types.contains("mRNA"))
        XCTAssertTrue(types.contains("CDS"))
    }

    func testQueryCountWithGeneName() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 500,
                     attributes: "ID=g1;Name=BRCA1;gene=BRCA1"),
            gff3Line(seqid: "chr1", type: "mRNA", start: 100, end: 500,
                     attributes: "ID=m1;Parent=g1;Name=XM_999;gene=BRCA1"),
        ]
        let (db, _) = try await createAndOpenDBFromGFF3(lines: lines)

        let count = db.queryCount(nameFilter: "BRCA1")
        XCTAssertEqual(count, 2, "BRCA1 should match gene (by name) and mRNA (by gene_name)")
    }

    func testCreateFromBEDExtractsGeneName() throws {
        let lines = [
            bed14(chrom: "chr1", start: 100, end: 500, name: "XM_001", type: "mRNA",
                  attributes: "gene=BRCA1;product=mRNA"),
        ]
        let (db, _) = try createAndOpenDB(lines: lines)

        // Searching "BRCA1" should find the mRNA by its gene_name
        let results = db.query(nameFilter: "BRCA1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "XM_001")
        XCTAssertEqual(results.first?.geneName, "BRCA1")
    }

    func testGeneNameColumnDetected() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 100, end: 500,
                     attributes: "ID=g1;Name=TestGene;gene=TestGene"),
        ]
        let (db, _) = try await createAndOpenDBFromGFF3(lines: lines)
        // Verify gene_name is populated (column always present in v4 schema)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.first?.geneName, "TestGene")
    }

    func testGeneNameNilWhenAbsent() async throws {
        // Feature without gene= attribute should have nil geneName
        let lines = [
            gff3Line(seqid: "chr1", type: "region", start: 1, end: 100000,
                     attributes: "ID=r1;Name=chromosome1"),
        ]
        let (db, _) = try await createAndOpenDBFromGFF3(lines: lines)
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 200000)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.geneName, "Region without gene attribute should have nil geneName")
    }

    func testLookupAnnotationReturnsGeneName() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "gene", start: 101, end: 500,
                     attributes: "ID=g1;Name=TestGene;gene=TestGene"),
        ]
        let (db, _) = try await createAndOpenDBFromGFF3(lines: lines)
        let record = db.lookupAnnotation(name: "TestGene", chromosome: "chr1", start: 100, end: 500)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.geneName, "TestGene")
    }

    func testLookupAnnotationMatchesByGeneName() async throws {
        let lines = [
            gff3Line(seqid: "chr1", type: "CDS", start: 101, end: 500,
                     attributes: "ID=cds1;Name=XP_001;gene=GZMB"),
        ]
        let (db, _) = try await createAndOpenDBFromGFF3(lines: lines)

        let record = db.lookupAnnotation(name: "GZMB", chromosome: "chr1", start: 100, end: 500)
        XCTAssertNotNil(record, "lookupAnnotation should match by gene_name fallback")
        XCTAssertEqual(record?.name, "XP_001")
        XCTAssertEqual(record?.geneName, "GZMB")
    }

    func testCreateFromGFF3SameIDAcrossTypesDoesNotMerge() async throws {
        let lines = [
            "##gff-version 3",
            gff3Line(seqid: "chr1", type: "CDS", start: 100, end: 150,
                     attributes: "ID=shared1;Name=cdsA;gene=GENE1"),
            gff3Line(seqid: "chr1", type: "regulatory", start: 200, end: 260,
                     attributes: "ID=shared1;Name=regA;gene=GENE1"),
        ]
        let (db, count) = try await createAndOpenDBFromGFF3(lines: lines)

        XCTAssertEqual(count, 2, "Non-CDS features sharing ID must not be merged away")
        let results = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map(\.type)), Set(["CDS", "regulatory"]))
    }
}
