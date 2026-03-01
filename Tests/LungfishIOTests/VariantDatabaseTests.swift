// VariantDatabaseTests.swift - Tests for VariantDatabase SQLite variant storage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import os
@testable import LungfishIO
@testable import LungfishCore

final class VariantDatabaseTests: XCTestCase {

    // MARK: - Test Data

    /// Minimal VCF with various variant types
    private let testVCF = """
    ##fileformat=VCFv4.3
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
    ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele Frequency">
    ##INFO=<ID=END,Number=1,Type=Integer,Description="End position">
    ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
    ##contig=<ID=chr1,length=248956422>
    ##contig=<ID=chr2,length=242193529>
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t100\trs100\tA\tG\t30.0\tPASS\tDP=50;AF=0.25
    chr1\t200\trs200\tATCG\tA\t25.0\tPASS\tDP=40
    chr1\t300\trs300\tA\tATCG\t35.0\tq10\tDP=30
    chr1\t400\t.\tAT\tGC\t40.0\tPASS\tDP=60
    chr1\t500\t.\tA\tG,T\t45.0\t.\tDP=70;AF=0.1,0.05
    chr2\t1000\trs1000\tC\tT\t50.0\tPASS\tDP=80
    chr2\t2000\trs2000\tGGG\tG\t20.0\tLowQual\tDP=10
    """

    /// VCF with structural variant using END in INFO
    private let structuralVCF = """
    ##fileformat=VCFv4.3
    ##INFO=<ID=END,Number=1,Type=Integer,Description="End position">
    ##INFO=<ID=SVTYPE,Number=1,Type=String,Description="SV Type">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t1000\tsv1\tN\t<DEL>\t99.0\tPASS\tEND=5000;SVTYPE=DEL
    chr1\t10000\tsv2\tN\t<DUP>\t80.0\tPASS\tEND=15000;SVTYPE=DUP
    """

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantDatabaseTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func createTempVCF(content: String, name: String = "test.vcf") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func createDatabase(from vcfContent: String) throws -> (VariantDatabase, URL) {
        let vcfURL = try createTempVCF(content: vcfContent)
        let dbURL = tempDir.appendingPathComponent("test.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let db = try VariantDatabase(url: dbURL)
        return (db, dbURL)
    }

    // MARK: - Creation Tests

    func testCreateFromVCF() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("variants.db")
        let count = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        XCTAssertEqual(count, 7, "Should insert 7 variant records")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }

    func testCreateFromVCFPartitionedByChromosome() throws {
        let vcf = """
        ##fileformat=VCFv4.3
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##contig=<ID=chr1,length=1000000>
        ##contig=<ID=chr2,length=1000000>
        ##contig=<ID=chrM,length=16569>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ts1\ts2
        chr2\t100\trs1\tA\tG\t30\tPASS\tDP=10\tGT\t0/1\t0/0
        chr1\t200\trs2\tC\tT\t31\tPASS\tDP=11\tGT\t1/1\t0/1
        chr2\t300\trs3\tG\tA\t32\tPASS\tDP=12\tGT\t0/1\t./.
        chrM\t50\trs4\tT\tC\t33\tPASS\tDP=13\tGT\t1/1\t1/1
        """

        let vcfURL = try createTempVCF(content: vcf, name: "partitioned.vcf")
        let dbURL = tempDir.appendingPathComponent("partitioned.db")
        let count = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            parseGenotypes: true,
            partitionByChromosome: true
        )

        XCTAssertEqual(count, 4)
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "import_partition_mode"), "per-chromosome")

        let db = try VariantDatabase(url: dbURL)
        XCTAssertEqual(db.totalCount(), 4)
        XCTAssertEqual(Set(db.allChromosomes()), Set(["chr1", "chr2", "chrM"]))
        XCTAssertEqual(db.sampleCount(), 2)
        XCTAssertEqual(db.query(chromosome: "chr2", start: 0, end: 1_000).count, 2)
    }

    func testMergeImportedDatabaseFromChromosomePartitions() throws {
        let vcf = """
        ##fileformat=VCFv4.3
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##contig=<ID=chr1,length=1000000>
        ##contig=<ID=chr2,length=1000000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ts1\ts2
        chr1\t100\trs1\tA\tG\t30\tPASS\tDP=10\tGT\t0/1\t0/0
        chr2\t200\trs2\tC\tT\t31\tPASS\tDP=11\tGT\t1/1\t0/1
        """

        let vcfURL = try createTempVCF(content: vcf, name: "merge.vcf")
        let dbAURL = tempDir.appendingPathComponent("chr1.db")
        let dbBURL = tempDir.appendingPathComponent("chr2.db")

        let countA = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbAURL,
            parseGenotypes: true,
            onlyChromosome: "chr1"
        )
        let countB = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbBURL,
            parseGenotypes: true,
            onlyChromosome: "chr2"
        )
        XCTAssertEqual(countA, 1)
        XCTAssertEqual(countB, 1)

        let mergedCount = try VariantDatabase.mergeImportedDatabase(into: dbAURL, from: dbBURL)
        XCTAssertEqual(mergedCount, 1)

        let mergedDB = try VariantDatabase(url: dbAURL)
        XCTAssertEqual(mergedDB.totalCount(), 2)
        XCTAssertEqual(mergedDB.query(chromosome: "chr1", start: 0, end: 1_000).count, 1)
        XCTAssertEqual(mergedDB.query(chromosome: "chr2", start: 0, end: 1_000).count, 1)
        XCTAssertEqual(mergedDB.sampleCount(), 2)
        XCTAssertEqual(
            VariantDatabase.metadataValue(at: dbAURL, key: "import_partition_mode"),
            "helper-subprocess-per-chromosome"
        )
    }

    func testCreateFromVCFOverwritesExisting() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("variants.db")

        // Create twice - should overwrite
        let count1 = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let count2 = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        XCTAssertEqual(count1, count2)
    }

    func testCreateFromEmptyVCF() throws {
        let emptyVCF = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """
        let vcfURL = try createTempVCF(content: emptyVCF)
        let dbURL = tempDir.appendingPathComponent("empty.db")
        let count = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        XCTAssertEqual(count, 0, "Empty VCF should produce 0 records")
    }

    // MARK: - Open / Close Tests

    func testOpenDatabase() throws {
        let (db, _) = try createDatabase(from: testVCF)
        XCTAssertEqual(db.totalCount(), 7)
    }

    func testOpenNonexistentDatabase() {
        let url = tempDir.appendingPathComponent("nonexistent.db")
        // VariantDatabase opens in READONLY mode, so nonexistent file should throw
        XCTAssertThrowsError(try VariantDatabase(url: url)) { error in
            XCTAssertTrue(error is VariantDatabaseError)
        }
    }

    func testOpenRejectsUnsupportedSchemaVersion() throws {
        let dbURL = tempDir.appendingPathComponent("unsupported_schema.db")
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &rawDB), SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        XCTAssertNotNil(rawDB)
        XCTAssertEqual(sqlite3_exec(rawDB, """
            CREATE TABLE variants (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chromosome TEXT NOT NULL,
                position INTEGER NOT NULL,
                end_pos INTEGER NOT NULL,
                variant_id TEXT NOT NULL,
                ref TEXT NOT NULL,
                alt TEXT NOT NULL,
                variant_type TEXT NOT NULL,
                quality REAL,
                filter TEXT,
                info TEXT,
                sample_count INTEGER DEFAULT 0
            );
            CREATE TABLE genotypes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                variant_id INTEGER NOT NULL,
                sample_name TEXT NOT NULL,
                genotype TEXT,
                allele1 INTEGER NOT NULL DEFAULT -1,
                allele2 INTEGER NOT NULL DEFAULT -1,
                is_phased INTEGER NOT NULL DEFAULT 0,
                depth INTEGER,
                genotype_quality INTEGER,
                allele_depths TEXT,
                raw_fields TEXT
            );
            CREATE TABLE samples (name TEXT PRIMARY KEY, display_name TEXT, source_file TEXT);
            CREATE TABLE variant_info (variant_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT);
            CREATE TABLE variant_info_defs (key TEXT PRIMARY KEY, type TEXT NOT NULL, number TEXT NOT NULL, description TEXT);
            CREATE TABLE db_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO db_metadata VALUES ('schema_version', '2');
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try VariantDatabase(url: dbURL)) { error in
            guard case VariantDatabaseError.invalidSchema(let message) = error else {
                return XCTFail("Expected invalidSchema error, got \(error)")
            }
            XCTAssertTrue(message.contains("Unsupported schema_version"))
        }
    }

    // MARK: - Total Count Tests

    func testTotalCount() throws {
        let (db, _) = try createDatabase(from: testVCF)
        XCTAssertEqual(db.totalCount(), 7)
    }

    // MARK: - All Types Tests

    func testAllTypes() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let types = db.allTypes()

        XCTAssertTrue(types.contains("SNP"), "Should contain SNP type")
        XCTAssertTrue(types.contains("DEL"), "Should contain DEL type")
        XCTAssertTrue(types.contains("INS"), "Should contain INS type")
        XCTAssertTrue(types.contains("MNP"), "Should contain MNP type")
    }

    // MARK: - All Chromosomes Tests

    func testAllChromosomes() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let chroms = db.allChromosomes()

        XCTAssertEqual(chroms.count, 2)
        XCTAssertTrue(chroms.contains("chr1"))
        XCTAssertTrue(chroms.contains("chr2"))
    }

    // MARK: - Region Query Tests

    func testQueryFullChromosome() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 0, end: 1000)

        XCTAssertEqual(results.count, 5, "chr1 should have 5 variants")
    }

    func testQueryNarrowRegion() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // Position 100 (0-based: 99) with ref length 1 -> end = 100
        // Query [90, 110) should overlap variant at position 99
        let results = db.query(chromosome: "chr1", start: 90, end: 110)

        XCTAssertEqual(results.count, 1, "Should find exactly 1 SNP in [90, 110)")
        XCTAssertEqual(results.first?.variantID, "rs100")
    }

    func testQueryNoResults() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 5000, end: 6000)

        XCTAssertTrue(results.isEmpty, "No variants in [5000, 6000)")
    }

    func testQueryNonexistentChromosome() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chrX", start: 0, end: 1000000)

        XCTAssertTrue(results.isEmpty)
    }

    func testQueryWithTypeFilter() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let snps = db.query(chromosome: "chr1", start: 0, end: 1000, types: ["SNP"])

        XCTAssertEqual(snps.count, 2, "chr1 should have 2 SNPs (rs100 and multi-allelic at 500)")
        for snp in snps {
            XCTAssertEqual(snp.variantType, "SNP")
        }
    }

    func testQueryWithMultipleTypeFilter() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 0, end: 1000, types: ["SNP", "INS"])

        // 2 SNPs + 1 insertion = 3
        XCTAssertEqual(results.count, 3)
    }

    func testQueryWithMinQuality() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 0, end: 1000, minQuality: 35.0)

        // Variants with quality >= 35.0: rs300(35), chr1_400(40), chr1_500(45)
        XCTAssertEqual(results.count, 3)
    }

    func testQueryOnlyPassing() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 0, end: 1000, onlyPassing: true)

        // PASS: rs100(30), rs200(25), chr1_400(40) = 3
        // q10: rs300 -> excluded
        // ".": chr1_500 -> treated as PASS
        XCTAssertEqual(results.count, 4)
    }

    func testQueryWithLimit() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 0, end: 1000, limit: 2)

        XCTAssertEqual(results.count, 2, "Limit should cap results at 2")
    }

    func testQueryOrderedByPosition() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 0, end: 1000)

        for i in 1..<results.count {
            XCTAssertGreaterThanOrEqual(results[i].position, results[i-1].position,
                                       "Results should be ordered by position")
        }
    }

    // MARK: - Variant Type Classification Tests

    func testSNPClassification() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 90, end: 110)

        XCTAssertEqual(results.first?.variantType, "SNP")
        XCTAssertEqual(results.first?.ref, "A")
        XCTAssertEqual(results.first?.alt, "G")
    }

    func testDeletionClassification() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 190, end: 210)

        XCTAssertEqual(results.first?.variantType, "DEL")
        XCTAssertEqual(results.first?.ref, "ATCG")
        XCTAssertEqual(results.first?.alt, "A")
    }

    func testInsertionClassification() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 290, end: 310)

        XCTAssertEqual(results.first?.variantType, "INS")
        XCTAssertEqual(results.first?.ref, "A")
        XCTAssertEqual(results.first?.alt, "ATCG")
    }

    func testMNPClassification() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 390, end: 410)

        XCTAssertEqual(results.first?.variantType, "MNP")
        XCTAssertEqual(results.first?.ref, "AT")
        XCTAssertEqual(results.first?.alt, "GC")
    }

    // MARK: - Coordinate Conversion Tests

    func testZeroBasedCoordinates() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // VCF position 100 (1-based) -> database position 99 (0-based)
        let results = db.query(chromosome: "chr1", start: 99, end: 100)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.position, 99, "Should be stored as 0-based")
        XCTAssertEqual(results.first?.end, 100, "End should be 0-based exclusive (99 + 1)")
    }

    func testDeletionEndPosition() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // VCF: chr1 200 rs200 ATCG A -> 0-based: position=199, end=199+4=203
        let results = db.query(chromosome: "chr1", start: 199, end: 203)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.variantID, "rs200")
        XCTAssertEqual(results.first?.position, 199)
        XCTAssertEqual(results.first?.end, 203, "Deletion ATCG: end = 199 + 4 = 203")
    }

    // MARK: - Structural Variant Tests

    func testStructuralVariantEndPosition() throws {
        let (db, _) = try createDatabase(from: structuralVCF)
        let results = db.query(chromosome: "chr1", start: 0, end: 20000)

        XCTAssertEqual(results.count, 2)

        // sv1: POS=1000 -> 0-based=999, END=5000 (from INFO)
        let sv1 = results.first { $0.variantID == "sv1" }
        XCTAssertNotNil(sv1)
        XCTAssertEqual(sv1?.position, 999)
        XCTAssertEqual(sv1?.end, 5000, "Should use END from INFO field")
    }

    func testStructuralVariantOverlapQuery() throws {
        let (db, _) = try createDatabase(from: structuralVCF)

        // Query region [3000, 4000) should overlap sv1 (999-5000) but not sv2 (9999-15000)
        let results = db.query(chromosome: "chr1", start: 3000, end: 4000)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.variantID, "sv1")
    }

    // MARK: - Query Count Tests

    func testQueryCount() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let count = db.queryCount(chromosome: "chr1", start: 0, end: 1000)

        XCTAssertEqual(count, 5)
    }

    func testQueryCountEmpty() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let count = db.queryCount(chromosome: "chr1", start: 5000, end: 6000)

        XCTAssertEqual(count, 0)
    }

    // MARK: - Search By ID Tests

    func testSearchByID() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // "rs100" substring matches both "rs100" and "rs1000"
        let results = db.searchByID(idFilter: "rs100")

        XCTAssertEqual(results.count, 2)
        let ids = results.map(\.variantID)
        XCTAssertTrue(ids.contains("rs100"))
        XCTAssertTrue(ids.contains("rs1000"))
    }

    func testSearchByIDSubstring() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // "rs" should match rs100, rs200, rs300, rs1000, rs2000
        let results = db.searchByID(idFilter: "rs")

        XCTAssertEqual(results.count, 5)
    }

    func testSearchByIDNoResults() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.searchByID(idFilter: "nonexistent")

        XCTAssertTrue(results.isEmpty)
    }

    func testSearchByIDEmpty() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.searchByID(idFilter: "")

        XCTAssertTrue(results.isEmpty, "Empty filter should return no results")
    }

    // MARK: - Record Conversion Tests

    func testToBundleVariant() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 90, end: 110)
        let record = try XCTUnwrap(results.first)

        let bundleVariant = record.toBundleVariant()

        XCTAssertEqual(bundleVariant.chromosome, "chr1")
        XCTAssertEqual(bundleVariant.position, 99)
        XCTAssertEqual(bundleVariant.ref, "A")
        XCTAssertEqual(bundleVariant.alt, ["G"])
        XCTAssertNotNil(bundleVariant.quality)
        XCTAssertEqual(Double(bundleVariant.quality ?? 0), 30.0, accuracy: 0.1)
        XCTAssertEqual(bundleVariant.variantId, "rs100")
        XCTAssertEqual(bundleVariant.filter, "PASS")
    }

    func testToAnnotation() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 90, end: 110)
        let record = try XCTUnwrap(results.first)

        let annotation = record.toAnnotation()

        XCTAssertEqual(annotation.type, .snp)
        XCTAssertEqual(annotation.name, "rs100")
        XCTAssertEqual(annotation.start, 99)
        XCTAssertEqual(annotation.end, 100)
        XCTAssertEqual(annotation.strand, .unknown)
        XCTAssertNotNil(annotation.color)
        XCTAssertNotNil(annotation.note)
    }

    func testDeletionAnnotationType() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 190, end: 210)
        let record = try XCTUnwrap(results.first)

        let annotation = record.toAnnotation()
        XCTAssertEqual(annotation.type, .deletion)
    }

    func testInsertionAnnotationType() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 290, end: 310)
        let record = try XCTUnwrap(results.first)

        let annotation = record.toAnnotation()
        XCTAssertEqual(annotation.type, .insertion)
    }

    func testMNPAnnotationType() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 390, end: 410)
        let record = try XCTUnwrap(results.first)

        let annotation = record.toAnnotation()
        XCTAssertEqual(annotation.type, .variation)
    }

    // MARK: - Quality and Filter Tests

    func testQualityPreserved() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 90, end: 110)
        let record = try XCTUnwrap(results.first)

        XCTAssertNotNil(record.quality)
        XCTAssertEqual(record.quality ?? 0, 30.0, accuracy: 0.01)
    }

    func testFilterPreserved() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // rs300 has filter "q10"
        let results = db.query(chromosome: "chr1", start: 290, end: 310)
        let record = try XCTUnwrap(results.first)

        XCTAssertEqual(record.filter, "q10")
    }

    func testNullQuality() throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t.\tPASS\t.
        """
        let (db, _) = try createDatabase(from: vcf)
        let results = db.query(chromosome: "chr1", start: 0, end: 200)

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.quality)
    }

    func testNullFilter() throws {
        let vcf = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\t.\t.
        """
        let (db, _) = try createDatabase(from: vcf)
        let results = db.query(chromosome: "chr1", start: 0, end: 200)

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.filter)
    }

    // MARK: - Multi-Allelic Tests

    func testMultiAllelicStored() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // chr1:500 has alt=G,T
        let results = db.query(chromosome: "chr1", start: 490, end: 510)
        let record = try XCTUnwrap(results.first)

        XCTAssertEqual(record.alt, "G,T")
    }

    // MARK: - INFO Field Tests

    func testInfoPreserved() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let results = db.query(chromosome: "chr1", start: 90, end: 110)
        let record = try XCTUnwrap(results.first)

        // v3: raw INFO string is not stored in variants table (redundant with variant_info EAV)
        XCTAssertNil(record.info, "v3 databases should not store raw INFO string")

        // Structured INFO values should be available
        let info = db.infoValues(variantId: record.id!)
        XCTAssertEqual(info["DP"], "50")
        XCTAssertEqual(info["AF"], "0.25")
    }

    // MARK: - Auto-Generated ID Tests

    func testAutoGeneratedID() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // chr1:400 has "." as ID -> should become "chr1_400"
        let results = db.query(chromosome: "chr1", start: 390, end: 410)
        let record = try XCTUnwrap(results.first)

        XCTAssertEqual(record.variantID, "chr1_400")
    }

    // MARK: - Large Scale Test

    func testLargeVCFCreation() throws {
        // Generate a VCF with 10,000 variants
        var lines = [
            "##fileformat=VCFv4.3",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO"
        ]
        for i in 1...10_000 {
            lines.append("chr1\t\(i * 10)\trs\(i)\tA\tG\t\(Double.random(in: 10...60))\tPASS\tDP=\(Int.random(in: 10...100))")
        }
        let content = lines.joined(separator: "\n")

        let vcfURL = try createTempVCF(content: content, name: "large.vcf")
        let dbURL = tempDir.appendingPathComponent("large.db")
        let count = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        XCTAssertEqual(count, 10_000)

        let db = try VariantDatabase(url: dbURL)
        XCTAssertEqual(db.totalCount(), 10_000)

        // Query a subset
        let results = db.query(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 100, "100 variants in [0, 1000) at 10bp intervals")

        // Count should match
        let countResult = db.queryCount(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(countResult, 100)
    }

    // MARK: - Edge Cases

    func testQueryAtExactPosition() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // SNP at 0-based position 99, end 100
        // Query [99, 100) should overlap
        let results = db.query(chromosome: "chr1", start: 99, end: 100)

        XCTAssertEqual(results.count, 1)
    }

    func testQueryJustBeforeVariant() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // SNP at 0-based position 99, end 100
        // Query [98, 99) should NOT overlap (end_pos=100 > start=98, but position=99 < end=99 fails)
        // Actually: position=99 < end=99 is false (99 < 99 is false)
        // But the condition is position < query_end AND end_pos > query_start
        // 99 < 99 = false, so should NOT match
        let results = db.query(chromosome: "chr1", start: 98, end: 99)

        XCTAssertTrue(results.isEmpty, "Region [98, 99) should not overlap variant at [99, 100)")
    }

    func testQueryJustAfterVariant() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // SNP at 0-based position 99, end 100
        // Query [100, 101) should NOT overlap: end_pos=100 > 100 is false
        let results = db.query(chromosome: "chr1", start: 100, end: 101)

        XCTAssertTrue(results.isEmpty, "Region [100, 101) should not overlap variant at [99, 100)")
    }

    func testVariantDatabaseRecordEquality() throws {
        let r1 = VariantDatabaseRecord(
            chromosome: "chr1", position: 99, end: 100, variantID: "rs1",
            ref: "A", alt: "G", variantType: "SNP",
            quality: 30.0, filter: "PASS", info: nil
        )
        let r2 = VariantDatabaseRecord(
            chromosome: "chr1", position: 99, end: 100, variantID: "rs1",
            ref: "A", alt: "G", variantType: "SNP",
            quality: 30.0, filter: "PASS", info: nil
        )

        XCTAssertEqual(r1, r2)
    }

    // MARK: - queryForTable Tests

    func testQueryForTableAllVariants() throws {
        let (db, _) = try createDatabase(from: testVCF)

        // No filters — should return all variants up to limit
        let results = db.queryForTable()
        XCTAssertEqual(results.count, 7, "Should return all 7 variants with no filters")
    }

    func testQueryForTableWithNameFilter() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let results = db.queryForTable(nameFilter: "rs100")
        XCTAssertTrue(results.count >= 1)
        XCTAssertTrue(results.allSatisfy { $0.variantID.contains("rs100") })
    }

    func testQueryForTableWithTypeFilter() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let snpResults = db.queryForTable(types: ["SNP"])
        XCTAssertTrue(snpResults.allSatisfy { $0.variantType == "SNP" })
        XCTAssertTrue(snpResults.count >= 2, "Should have at least 2 SNPs")

        let delResults = db.queryForTable(types: ["DEL"])
        XCTAssertTrue(delResults.allSatisfy { $0.variantType == "DEL" })
    }

    func testQueryForTableWithNameAndTypeFilter() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let results = db.queryForTable(nameFilter: "rs", types: ["SNP"])
        XCTAssertTrue(results.allSatisfy { $0.variantType == "SNP" })
        XCTAssertTrue(results.allSatisfy { $0.variantID.contains("rs") })
    }

    func testQueryForTableWithSampleFilter() throws {
        let vcf = """
        ##fileformat=VCFv4.3
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2
        chr1\t100\trs_s1\tA\tG\t30\tPASS\t.\tGT\t0/1\t0/0
        chr1\t200\trs_s2\tC\tT\t30\tPASS\t.\tGT\t0/0\t1/1
        chr1\t300\trs_none\tG\tA\t30\tPASS\t.\tGT\t0/0\t0/0
        """
        let (db, _) = try createDatabase(from: vcf)

        let s1Results = db.queryForTable(sampleNames: ["S1"])
        XCTAssertEqual(Set(s1Results.map(\.variantID)), ["rs_s1"])

        let s2Results = db.queryForTable(sampleNames: ["S2"])
        XCTAssertEqual(Set(s2Results.map(\.variantID)), ["rs_s2"])

        let countS1 = db.queryCountForTable(sampleNames: ["S1"])
        XCTAssertEqual(countS1, 1)
    }

    func testQueryCountForTable() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let totalCount = db.queryCountForTable()
        XCTAssertEqual(totalCount, 7)

        let snpCount = db.queryCountForTable(types: ["SNP"])
        XCTAssertTrue(snpCount >= 2)
        XCTAssertTrue(snpCount < totalCount)
    }

    func testInfoFilterParseRejectsInvalidNumericValue() {
        XCTAssertNil(VariantDatabase.InfoFilter.parse("DP>abc"))
        XCTAssertNil(VariantDatabase.InfoFilter.parse("AF<=notANumber"))
    }

    func testInfoFilterParseAllowsStringOperators() {
        let contains = VariantDatabase.InfoFilter.parse("gene~BRCA")
        XCTAssertEqual(contains?.key, "gene")
        XCTAssertEqual(contains?.op, .like)
        XCTAssertEqual(contains?.value, "BRCA")

        let eq = VariantDatabase.InfoFilter.parse("impact=HIGH")
        XCTAssertEqual(eq?.key, "impact")
        XCTAssertEqual(eq?.op, .eq)
        XCTAssertEqual(eq?.value, "HIGH")
    }

    // MARK: - Structured INFO Table Tests

    func testInfoTableCreated() throws {
        let (db, _) = try createDatabase(from: testVCF)

        // The database should have INFO field definitions and per-variant INFO values
        let keys = db.infoKeys()
        XCTAssertFalse(keys.isEmpty, "Should have parsed INFO definitions from VCF header")
    }

    func testInfoDefinitionsParsed() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let keys = db.infoKeys()
        let keyNames = keys.map(\.key)

        // The test VCF defines DP (Integer), AF (Float), END (Integer)
        XCTAssertTrue(keyNames.contains("DP"), "Should contain DP definition")
        XCTAssertTrue(keyNames.contains("AF"), "Should contain AF definition")
        XCTAssertTrue(keyNames.contains("END"), "Should contain END definition")

        // Check types
        let dpDef = keys.first(where: { $0.key == "DP" })
        XCTAssertEqual(dpDef?.type, "Integer")
        XCTAssertEqual(dpDef?.number, "1")

        let afDef = keys.first(where: { $0.key == "AF" })
        XCTAssertEqual(afDef?.type, "Float")
        XCTAssertEqual(afDef?.number, "A")
    }

    func testInfoValuesParsed() throws {
        let (db, _) = try createDatabase(from: testVCF)

        // The first variant (rs100) has INFO=DP=50;AF=0.25
        let results = db.query(chromosome: "chr1", start: 0, end: 200)
        guard let rs100 = results.first(where: { $0.variantID == "rs100" }), let rowId = rs100.id else {
            XCTFail("Could not find rs100")
            return
        }

        let info = db.infoValues(variantId: rowId)
        XCTAssertEqual(info["DP"], "50", "DP should be 50")
        XCTAssertEqual(info["AF"], "0.25", "AF should be 0.25")
    }

    func testInfoValuesForMultipleVariants() throws {
        let (db, _) = try createDatabase(from: testVCF)

        // chr1:500 has INFO=DP=70;AF=0.1,0.05 (multi-allelic)
        let results = db.query(chromosome: "chr1", start: 400, end: 600)
        guard let variant = results.first(where: { $0.position == 499 }), let rowId = variant.id else {
            XCTFail("Could not find variant at position 499")
            return
        }

        let info = db.infoValues(variantId: rowId)
        XCTAssertEqual(info["DP"], "70")
        XCTAssertEqual(info["AF"], "0.1,0.05")
    }

    func testQueryForTableInfoFilterUsesCaseInsensitiveInfoKey() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let filters = [VariantDatabase.InfoFilter(key: "dp", op: .gt, value: "60")]

        let results = db.queryForTable(infoFilters: filters)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map(\.variantID)), Set(["chr1_500", "rs1000"]))
    }

    func testQueryCountForTableInfoFilterUsesCaseInsensitiveInfoKey() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let filters = [VariantDatabase.InfoFilter(key: "dP", op: .gte, value: "70")]

        let count = db.queryCountForTable(infoFilters: filters)

        XCTAssertEqual(count, 2)
    }

    func testBatchInfoValues() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let allVariants = db.queryForTable()
        let allIds = allVariants.compactMap(\.id)
        XCTAssertEqual(allIds.count, 7)

        let batchInfo = db.batchInfoValues(variantIds: allIds)
        // Every variant in the test VCF has at least a DP field
        XCTAssertTrue(batchInfo.count >= 7, "Should have INFO for all variants")
        for (_, info) in batchInfo {
            XCTAssertTrue(info.keys.contains("DP"), "Every test variant has DP")
        }
    }

    func testBatchInfoValuesLargeVariantIDList() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let allVariants = db.queryForTable()
        let allIds = allVariants.compactMap(\.id)
        XCTAssertFalse(allIds.isEmpty)

        // Exercise bind-limit handling by requesting far more IDs than a single IN-clause should bind.
        let manyMissingIds = (1...35_000).map { Int64($0 + 1_000_000) }
        let requestIds = allIds + manyMissingIds
        let batchInfo = db.batchInfoValues(variantIds: requestIds)

        for id in allIds {
            XCTAssertNotNil(batchInfo[id], "Expected INFO dictionary for known variant id \(id)")
            XCTAssertEqual(batchInfo[id]?["DP"] != nil, true, "Expected DP key in INFO for id \(id)")
        }
    }

    func testInfoKeysQuery() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let keys = db.infoKeys()
        XCTAssertTrue(keys.count >= 3, "Should have at least DP, AF, END")

        // Verify descriptions are parsed
        let dpDef = keys.first(where: { $0.key == "DP" })
        XCTAssertEqual(dpDef?.description, "Total Depth")
    }

    func testInfoDefinitionParsesEscapedQuotesAndCommas() throws {
        let vcf = """
        ##fileformat=VCFv4.3
        ##INFO=<ID=NOTE,Number=1,Type=String,Description="Contains comma, and \\\"quoted\\\" text">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t50\tPASS\tNOTE=alpha
        """
        let (db, _) = try createDatabase(from: vcf)
        let noteDef = db.infoKeys().first(where: { $0.key == "NOTE" })
        XCTAssertEqual(noteDef?.type, "String")
        XCTAssertEqual(noteDef?.description, "Contains comma, and \"quoted\" text")
    }

    func testDeleteVariantsCascadesToInfo() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("delete_info.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        let db = try VariantDatabase(url: dbURL, readWrite: true)
        let allVariants = db.queryForTable()
        guard let firstId = allVariants.first?.id else {
            XCTFail("No variants found")
            return
        }

        // Verify INFO exists before deletion
        let infoBefore = db.infoValues(variantId: firstId)
        XCTAssertFalse(infoBefore.isEmpty, "Should have INFO before deletion")

        // Delete the first variant
        let deleted = try db.deleteVariants(ids: [firstId])
        XCTAssertEqual(deleted, 1)

        // Verify INFO is gone after deletion
        let infoAfter = db.infoValues(variantId: firstId)
        XCTAssertTrue(infoAfter.isEmpty, "INFO should be deleted with variant")
    }

    func testDeleteAllVariantsCascadesToInfo() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("delete_all_info.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        let db = try VariantDatabase(url: dbURL, readWrite: true)

        // Verify we have INFO values
        let allVariants = db.queryForTable()
        let allIds = allVariants.compactMap(\.id)
        let batchBefore = db.batchInfoValues(variantIds: allIds)
        XCTAssertFalse(batchBefore.isEmpty, "Should have INFO before delete all")

        // Delete all
        let deleted = try db.deleteAllVariants()
        XCTAssertEqual(deleted, 7)

        // Verify no INFO remains
        let batchAfter = db.batchInfoValues(variantIds: allIds)
        XCTAssertTrue(batchAfter.isEmpty, "All INFO should be deleted")
    }

    func testInfoFlagParsed() throws {
        // VCF with flag-only INFO fields
        let flagVCF = """
        ##fileformat=VCFv4.3
        ##INFO=<ID=DB,Number=0,Type=Flag,Description="dbSNP membership">
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs100\tA\tG\t30.0\tPASS\tDB;DP=50
        """
        let (db, _) = try createDatabase(from: flagVCF)

        let results = db.queryForTable()
        guard let variant = results.first, let rowId = variant.id else {
            XCTFail("No variant found")
            return
        }

        let info = db.infoValues(variantId: rowId)
        XCTAssertEqual(info["DB"], "true", "Flag-only INFO should be stored as 'true'")
        XCTAssertEqual(info["DP"], "50")

        // Verify definitions include the Flag type
        let keys = db.infoKeys()
        let dbDef = keys.first(where: { $0.key == "DB" })
        XCTAssertEqual(dbDef?.type, "Flag")
        XCTAssertEqual(dbDef?.number, "0")
    }

    // MARK: - Ultra Low Memory / OOM Robustness Tests

    func testUltraLowMemoryProfileAutoSelection() {
        // Files >= 5 GB should select ultra-low-memory.
        // We test this indirectly by importing with the .auto profile and a simulated
        // large-file size.  Since we can't control resolveImportProfile directly (it's
        // private), we verify the public enum has the new case and that imports with
        // the explicit profile succeed.
        XCTAssertNotNil(VCFImportProfile(rawValue: "ultra-low-memory"))
        XCTAssertEqual(VCFImportProfile.ultraLowMemory.rawValue, "ultra-low-memory")
    }

    func testUltraLowMemoryProducesSameVariants() throws {
        // Import the same VCF twice: once with fast (EAV + bulk indexes) and once with
        // ultra-low-memory (no EAV, deferred indexes).  Variant data should be identical.
        let vcfURL = try createTempVCF(content: testVCF)

        let dbFastURL = tempDir.appendingPathComponent("fast.db")
        let countFast = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbFastURL,
            parseGenotypes: true, importProfile: .fast
        )
        let dbFast = try VariantDatabase(url: dbFastURL)

        let dbUltraURL = tempDir.appendingPathComponent("ultra.db")
        let countUltra = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbUltraURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )
        let dbUltra = try VariantDatabase(url: dbUltraURL)

        XCTAssertEqual(countFast, countUltra, "Both import modes should produce the same variant count")
        XCTAssertEqual(countFast, 7)

        // Region query should return same variant records.
        let regionFast = dbFast.query(chromosome: "chr1", start: 0, end: 1000)
        let regionUltra = dbUltra.query(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(regionFast.count, regionUltra.count)

        for (f, u) in zip(regionFast, regionUltra) {
            XCTAssertEqual(f.variantID, u.variantID)
            XCTAssertEqual(f.position, u.position)
            XCTAssertEqual(f.ref, u.ref)
            XCTAssertEqual(f.alt, u.alt)
        }

        // Ultra-low-memory stores raw INFO; fast stores NULL (uses EAV instead).
        XCTAssertTrue(dbUltra.variantInfoSkipped)
        XCTAssertFalse(dbFast.variantInfoSkipped)
        // But infoValues should return equivalent results from both.
        if let fastId = regionFast.first?.id, let ultraId = regionUltra.first?.id {
            let fastInfo = dbFast.infoValues(variantId: fastId)
            let ultraInfo = dbUltra.infoValues(variantId: ultraId)
            XCTAssertEqual(fastInfo, ultraInfo, "INFO values should match regardless of storage mode")
        }
    }

    func testUltraLowMemoryDeferredIndexBuildThenResume() throws {
        let vcfURL = try createTempVCF(content: testVCF, name: "ultra_deferred.vcf")
        let dbURL = tempDir.appendingPathComponent("ultra_deferred.db")

        let inserted = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            parseGenotypes: true,
            importProfile: .ultraLowMemory,
            deferIndexBuild: true
        )
        XCTAssertEqual(inserted, 7)
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "indexing")

        // Insert phase should still produce queryable rows even before indexes.
        let preResumeDB = try VariantDatabase(url: dbURL)
        XCTAssertEqual(preResumeDB.query(chromosome: "chr1", start: 0, end: 1000).count, 5)

        let resumedCount = try VariantDatabase.resumeImport(existingDBURL: dbURL)
        XCTAssertEqual(resumedCount, 7)
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "complete")

        let db = try VariantDatabase(url: dbURL)
        XCTAssertEqual(db.query(chromosome: "chr1", start: 0, end: 1000).count, 5)
    }

    func testImportStateTracking() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("state.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        // After successful import, state should be 'complete'.
        let state = VariantDatabase.importState(at: dbURL)
        XCTAssertEqual(state, "complete")
    }

    func testImportStateNilForMissingFile() {
        let bogusURL = tempDir.appendingPathComponent("nonexistent.db")
        XCTAssertNil(VariantDatabase.importState(at: bogusURL))
    }

    func testContigLengthsStoredDuringImport() throws {
        // The testVCF has ##contig lines: chr1=248956422, chr2=242193529
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("contigs.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        let db = try VariantDatabase(url: dbURL)
        let contigs = db.contigLengths()
        XCTAssertEqual(contigs["chr1"], 248956422)
        XCTAssertEqual(contigs["chr2"], 242193529)
        XCTAssertEqual(contigs.count, 2)
    }

    func testContigLengthsEmptyForNoContigHeaders() throws {
        // VCF without ##contig lines
        let vcfNoContigs = """
        ##fileformat=VCFv4.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs100\tA\tG\t30.0\tPASS\tDP=50
        """
        let vcfURL = try createTempVCF(content: vcfNoContigs)
        let dbURL = tempDir.appendingPathComponent("no_contigs.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        let db = try VariantDatabase(url: dbURL)
        let contigs = db.contigLengths()
        XCTAssertTrue(contigs.isEmpty)
    }

    func testResumeInterruptedIndexing() throws {
        // Simulate an interrupted import: create a database with data but no indexes
        // and import_state = 'indexing'.
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("interrupted.db")

        // First, do a normal import.
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        // Now open the DB and drop all our indexes + set state to 'indexing'
        // to simulate a crash after inserts but before index completion.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        for idx in ["idx_variants_region", "idx_variants_type", "idx_variants_id",
                     "idx_genotypes_sample", "idx_genotypes_variant", "idx_samples_name",
                     "idx_variant_info_key", "idx_variant_info_key_value"] {
            sqlite3_exec(db, "DROP INDEX IF EXISTS \(idx)", nil, nil, nil)
        }
        sqlite3_exec(db, "UPDATE db_metadata SET value = 'indexing' WHERE key = 'import_state'", nil, nil, nil)
        sqlite3_close(db)

        // Confirm state is 'indexing' before resume.
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "indexing")

        // Resume should recreate the indexes.
        let count = try VariantDatabase.resumeImport(existingDBURL: dbURL)
        XCTAssertEqual(count, 7)

        // State should now be complete.
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "complete")

        // Queries should still work (indexes exist).
        let resumed = try VariantDatabase(url: dbURL)
        let results = resumed.query(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 5)
    }

    func testResumeAlreadyComplete() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("complete.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        // Resuming a complete import should just return the count.
        let count = try VariantDatabase.resumeImport(existingDBURL: dbURL)
        XCTAssertEqual(count, 7)
    }

    func testResumeRejectsInsertingState() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("inserting.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "UPDATE db_metadata SET value = 'inserting' WHERE key = 'import_state'", nil, nil, nil)
        sqlite3_close(db)

        XCTAssertThrowsError(try VariantDatabase.resumeImport(existingDBURL: dbURL)) { error in
            guard case VariantDatabaseError.invalidSchema(let message) = error else {
                XCTFail("Expected invalidSchema, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("inserting"))
            XCTAssertTrue(message.contains("restart full import"))
        }
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "inserting")
    }

    func testResumeRejectsMissingImportState() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("missing_state.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "DELETE FROM db_metadata WHERE key = 'import_state'", nil, nil, nil)
        sqlite3_close(db)

        XCTAssertThrowsError(try VariantDatabase.resumeImport(existingDBURL: dbURL)) { error in
            guard case VariantDatabaseError.invalidSchema(let message) = error else {
                XCTFail("Expected invalidSchema, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("missing import_state"))
            XCTAssertTrue(message.contains("restart full import"))
        }
        XCTAssertNil(VariantDatabase.importState(at: dbURL))
    }

    func testMaxVariantInfoKeysPerVariant() throws {
        // VCF with many INFO fields per variant.
        let manyInfoVCF = """
        ##fileformat=VCFv4.3
        ##INFO=<ID=A,Number=1,Type=String,Description="A">
        ##INFO=<ID=B,Number=1,Type=String,Description="B">
        ##INFO=<ID=C,Number=1,Type=String,Description="C">
        ##INFO=<ID=D,Number=1,Type=String,Description="D">
        ##INFO=<ID=E,Number=1,Type=String,Description="E">
        ##INFO=<ID=F,Number=1,Type=String,Description="F">
        ##INFO=<ID=G,Number=1,Type=String,Description="G">
        ##INFO=<ID=H,Number=1,Type=String,Description="H">
        ##INFO=<ID=I,Number=1,Type=String,Description="I">
        ##INFO=<ID=J,Number=1,Type=String,Description="J">
        ##INFO=<ID=K,Number=1,Type=String,Description="K">
        ##INFO=<ID=L,Number=1,Type=String,Description="L">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30.0\tPASS\tA=1;B=2;C=3;D=4;E=5;F=6;G=7;H=8;I=9;J=10;K=11;L=12
        """

        // With ultra-low-memory profile, variant_info EAV is skipped entirely.
        // infoValues should still return all keys by parsing raw INFO from variants.info.
        let vcfURL = try createTempVCF(content: manyInfoVCF, name: "many_info.vcf")
        let dbURL = tempDir.appendingPathComponent("many_info.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )

        let db = try VariantDatabase(url: dbURL)
        XCTAssertTrue(db.variantInfoSkipped, "Ultra-low-memory should set skip_variant_info")
        let variants = db.query(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(variants.count, 1)

        // infoValues falls back to parsing raw INFO string.
        let rowId = try XCTUnwrap(variants[0].id)
        let info = db.infoValues(variantId: rowId)
        XCTAssertEqual(info.count, 12, "All 12 INFO keys should be available via raw INFO parsing")
        XCTAssertEqual(info["A"], "1")
        XCTAssertEqual(info["L"], "12")

        // Now import with fast profile (EAV table) — should store all 12 via EAV.
        let dbFullURL = tempDir.appendingPathComponent("many_info_full.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbFullURL,
            parseGenotypes: true, importProfile: .fast
        )
        let dbFull = try VariantDatabase(url: dbFullURL)
        XCTAssertFalse(dbFull.variantInfoSkipped, "Fast profile should NOT skip variant_info")
        let fullVariants = dbFull.query(chromosome: "chr1", start: 0, end: 1000)
        let fullRowId = try XCTUnwrap(fullVariants[0].id)
        let fullInfo = dbFull.infoValues(variantId: fullRowId)
        XCTAssertEqual(fullInfo.count, 12, "Fast profile should store all 12 INFO keys via EAV")
    }

    func testUltraLowMemorySkipsVariantInfoTable() throws {
        // Verify that ultraLowMemory stores raw INFO in variants.info
        // and leaves variant_info EAV table empty.
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("ultra_skip.db")
        let count = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )
        XCTAssertEqual(count, 7)

        let db = try VariantDatabase(url: dbURL)
        XCTAssertTrue(db.variantInfoSkipped)

        // The variant_info_defs table should be empty (no defs stored), but
        // infoKeys() now falls back to discoverInfoKeysFromRawInfo() for
        // skipVariantInfo databases, so it returns discovered keys.
        let defs = db.infoKeys()
        XCTAssertFalse(defs.isEmpty, "infoKeys() should discover keys from raw INFO for ultra-low-memory DBs")
        let keyNames = Set(defs.map(\.key))
        XCTAssertTrue(keyNames.contains("DP"), "Should discover DP from raw INFO")
        XCTAssertTrue(keyNames.contains("AF"), "Should discover AF from raw INFO")

        // But infoValues should still work via raw INFO parsing.
        let variants = db.query(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertFalse(variants.isEmpty)
        let rowId = try XCTUnwrap(variants[0].id)
        let info = db.infoValues(variantId: rowId)
        // The test VCF has INFO fields like AC=2;AF=1.00;AN=2;DP=100
        XCTAssertFalse(info.isEmpty, "Raw INFO parsing should return fields")

        // Raw INFO string should be stored in the record.
        let record = variants[0]
        XCTAssertNotNil(record.info, "variants.info should contain raw INFO string")
    }

    func testUltraLowMemoryBatchInfoValues() throws {
        // Verify batchInfoValues works for skipVariantInfo databases.
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("ultra_batch.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )

        let db = try VariantDatabase(url: dbURL)
        let variants = db.query(chromosome: "chr1", start: 0, end: 1000)
        let ids = variants.compactMap { $0.id }
        XCTAssertFalse(ids.isEmpty)

        let batch = db.batchInfoValues(variantIds: ids)
        XCTAssertEqual(batch.count, ids.count, "Batch should return results for all variants")
        for (_, infoDict) in batch {
            XCTAssertFalse(infoDict.isEmpty, "Each variant should have parsed INFO fields")
        }
    }

    func testResumeSkipVariantInfoDatabase() throws {
        // Verify that resumeImport correctly skips variant_info indexes for
        // databases imported with skipVariantInfo.
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("resume_skip_vi.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )

        // Drop some indexes and set state to 'indexing' to simulate crash.
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &rawDB), SQLITE_OK)
        sqlite3_exec(rawDB, "DROP INDEX IF EXISTS idx_variants_region", nil, nil, nil)
        sqlite3_exec(rawDB, "DROP INDEX IF EXISTS idx_variants_type", nil, nil, nil)
        sqlite3_exec(rawDB, "UPDATE db_metadata SET value = 'indexing' WHERE key = 'import_state'", nil, nil, nil)
        sqlite3_close(rawDB)

        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "indexing")

        // Resume should succeed and NOT try to create variant_info indexes.
        let count = try VariantDatabase.resumeImport(existingDBURL: dbURL)
        XCTAssertEqual(count, 7)
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "complete")

        // Should be queryable.
        let db = try VariantDatabase(url: dbURL)
        let results = db.query(chromosome: "chr1", start: 0, end: 1000)
        XCTAssertEqual(results.count, 5)
    }

    // MARK: - Materialization Tests

    func testMaterializeBasicEAV() throws {
        // Import with ultraLowMemory (skips variant_info), then materialize.
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("materialize_basic.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )

        // Verify variant_info is empty before materialization.
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &rawDB), SQLITE_OK)
        var countStmt: OpaquePointer?
        sqlite3_prepare_v2(rawDB, "SELECT COUNT(*) FROM variant_info", -1, &countStmt, nil)
        sqlite3_step(countStmt)
        XCTAssertEqual(sqlite3_column_int(countStmt, 0), 0)
        sqlite3_finalize(countStmt)
        sqlite3_close(rawDB)

        // Materialize.
        let eavCount = try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)
        XCTAssertGreaterThan(eavCount, 0)

        // Verify EAV rows match raw INFO for each variant.
        let db = try VariantDatabase(url: dbURL)
        let chr1 = db.query(chromosome: "chr1", start: 0, end: 1_000_000)
        for variant in chr1 {
            guard let vid = variant.id else { continue }
            let info = db.infoValues(variantId: vid)
            // Every variant in testVCF has at least DP
            XCTAssertNotNil(info["DP"], "Variant at \(variant.position) should have DP")
        }
    }

    func testMaterializeResumability() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("materialize_resume.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )

        // Start materialization and cancel after first batch progress callback.
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        _ = try? VariantDatabase.materializeVariantInfo(
            existingDBURL: dbURL,
            progressHandler: { _, _ in cancelFlag.withLock { $0 = true } },
            shouldCancel: { cancelFlag.withLock { $0 } }
        )

        // Should have cursor saved.
        let materializeState = VariantDatabase.metadataValue(at: dbURL, key: "materialize_state")
        // State is either "materializing" (cancelled mid-way) or "complete" (small dataset finished before cancel)
        XCTAssertNotNil(materializeState, "materialize_state should be set")

        // Resume should complete successfully regardless.
        let eavCount = try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)
        XCTAssertEqual(
            VariantDatabase.metadataValue(at: dbURL, key: "materialize_state"),
            "complete"
        )

        // Verify data is accessible.
        let db = try VariantDatabase(url: dbURL)
        let all = db.query(chromosome: "chr1", start: 0, end: 1_000_000)
            + db.query(chromosome: "chr2", start: 0, end: 10_000_000)
        XCTAssertEqual(all.count, 7)
        // After materialization, variant_info should not be "skipped" anymore.
        XCTAssertFalse(db.variantInfoSkipped)
        _ = eavCount  // suppress unused warning
    }

    func testMaterializeIdempotent() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("materialize_idempotent.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )

        let count1 = try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)
        XCTAssertGreaterThan(count1, 0)

        // Second call should return 0 (already complete).
        let count2 = try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)
        XCTAssertEqual(count2, 0)

        // Verify no duplicate rows.
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &rawDB, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(rawDB, "SELECT COUNT(*) FROM variant_info", -1, &stmt, nil)
        sqlite3_step(stmt)
        let totalRows = sqlite3_column_int(stmt, 0)
        sqlite3_finalize(stmt)
        sqlite3_close(rawDB)

        // count1 should equal total rows (no duplicates from second call).
        XCTAssertEqual(Int(totalRows), count1)
    }

    func testMaterializePopulatesInfoDefs() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("materialize_defs.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )

        // Before materialization, infoKeys() discovers keys from raw INFO
        // (variant_info_defs table itself is empty, but fallback discovery works).
        let dbBefore = try VariantDatabase(url: dbURL)
        XCTAssertTrue(dbBefore.variantInfoSkipped, "Should be skipVariantInfo before materialization")
        let discoveredBefore = dbBefore.infoKeys()
        XCTAssertFalse(discoveredBefore.isEmpty, "Should discover keys from raw INFO before materialization")

        try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)

        // After materialization, variant_info_defs should have entries and
        // variantInfoSkipped should be false.
        let dbAfter = try VariantDatabase(url: dbURL)
        XCTAssertFalse(dbAfter.variantInfoSkipped, "Should no longer be skipVariantInfo after materialization")
        let keys = dbAfter.infoKeys()
        let keyNames = Set(keys.map(\.key))
        // testVCF has DP and AF keys.
        XCTAssertTrue(keyNames.contains("DP"), "Should have DP in info defs")
        XCTAssertTrue(keyNames.contains("AF"), "Should have AF in info defs")
    }

    func testMaterializeFlipsSkipFlag() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("materialize_flag.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )

        // Before: skip flag is set.
        let dbBefore = try VariantDatabase(url: dbURL)
        XCTAssertTrue(dbBefore.variantInfoSkipped)

        try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)

        // After: skip flag is cleared — fresh open should see false.
        let dbAfter = try VariantDatabase(url: dbURL)
        XCTAssertFalse(dbAfter.variantInfoSkipped)
    }

    func testInfoQueriesWorkAfterMaterialize() throws {
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("materialize_queries.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )
        try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)

        let db = try VariantDatabase(url: dbURL)

        // infoValues should return data from EAV table (not raw parsing).
        let variants = db.query(chromosome: "chr1", start: 0, end: 1_000_000)
        let firstVariant = try XCTUnwrap(variants.first)
        let firstId = try XCTUnwrap(firstVariant.id)
        let info = db.infoValues(variantId: firstId)
        XCTAssertEqual(info["DP"], "50")
        XCTAssertEqual(info["AF"], "0.25")

        // distinctInfoValues should return values.
        let dpValues = db.distinctInfoValues(forKey: "DP")
        XCTAssertFalse(dpValues.isEmpty)

        // hasNonEmptyInfoValue should return true for known keys.
        XCTAssertTrue(db.hasNonEmptyInfoValue(forKey: "DP"))
        XCTAssertFalse(db.hasNonEmptyInfoValue(forKey: "NONEXISTENT_KEY"))

        // infoKeys should return entries.
        let keys = db.infoKeys()
        XCTAssertFalse(keys.isEmpty)
    }

    func testMaterializeOnNonSkippedDB() throws {
        // Standard import (not ultraLowMemory) — materialize should be a no-op.
        let vcfURL = try createTempVCF(content: testVCF)
        let dbURL = tempDir.appendingPathComponent("materialize_noop.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .fast
        )

        // Should return 0 since skip_variant_info is not set.
        let count = try VariantDatabase.materializeVariantInfo(existingDBURL: dbURL)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Query Timeout Tests

    func testInstallAndRemoveQueryTimeout() throws {
        let (db, _) = try createDatabase(from: testVCF)

        // Installing and removing the timeout should not crash.
        db.installQueryTimeout(seconds: 5.0)
        let results = db.queryForTable(limit: 10)
        XCTAssertFalse(results.isEmpty, "Query should still work with timeout installed")
        db.removeQueryTimeout()

        // After removing, queries should still work normally.
        let results2 = db.queryForTable(limit: 10)
        XCTAssertFalse(results2.isEmpty)
    }

    func testQueryTimeoutWithCancelCheck() throws {
        let (db, _) = try createDatabase(from: testVCF)

        // Install timeout with a cancel check that immediately cancels.
        db.installQueryTimeout(seconds: 60.0, cancelCheck: { true })
        let results = db.queryForTable(limit: 10)
        // With immediate cancellation, query should return empty or partial results.
        // On a small DB it may complete before the progress handler fires,
        // so we just verify no crash.
        db.removeQueryTimeout()

        // Normal query still works.
        let results2 = db.queryForTable(limit: 10)
        XCTAssertFalse(results2.isEmpty)
        _ = results  // suppress unused warning
    }

    func testQueryTimeoutDoesNotAffectFastQueries() throws {
        let (db, _) = try createDatabase(from: testVCF)

        db.installQueryTimeout(seconds: 1.0)
        let all = db.queryForTable(limit: 100)
        XCTAssertEqual(all.count, 7, "Fast query on small DB should complete within timeout")
        db.removeQueryTimeout()
    }

    // MARK: - Metadata Caching Tests

    func testTotalCountIsCached() throws {
        let (db, _) = try createDatabase(from: testVCF)

        // First call computes.
        let count1 = db.totalCount()
        XCTAssertEqual(count1, 7)

        // Second call should return cached value (same result, no recomputation).
        let count2 = db.totalCount()
        XCTAssertEqual(count2, 7)
        XCTAssertEqual(count1, count2)
    }

    func testAllTypesIsCached() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let types1 = db.allTypes()
        XCTAssertFalse(types1.isEmpty)

        let types2 = db.allTypes()
        XCTAssertEqual(types1, types2)
    }

    func testAllChromosomesIsCached() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let chroms1 = db.allChromosomes()
        XCTAssertTrue(chroms1.contains("chr1"))
        XCTAssertTrue(chroms1.contains("chr2"))

        let chroms2 = db.allChromosomes()
        XCTAssertEqual(chroms1, chroms2)
    }

    func testChromosomeMaxPositionsIsCached() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let maxPos1 = db.chromosomeMaxPositions()
        XCTAssertNotNil(maxPos1["chr1"])
        XCTAssertNotNil(maxPos1["chr2"])

        let maxPos2 = db.chromosomeMaxPositions()
        XCTAssertEqual(maxPos1, maxPos2)
    }

    func testChromosomeVariantCounts() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let counts = db.chromosomeVariantCounts()
        XCTAssertEqual(counts["chr1"], 5, "chr1 should have 5 variants")
        XCTAssertEqual(counts["chr2"], 2, "chr2 should have 2 variants")
    }

    // MARK: - High-Impact Cache Tests

    /// VCF with IMPACT annotations for testing the high-impact temp table cache.
    private let impactVCF = """
    ##fileformat=VCFv4.3
    ##INFO=<ID=IMPACT,Number=1,Type=String,Description="Variant impact">
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t100\trs100\tA\tG\t30.0\tPASS\tIMPACT=HIGH;DP=50
    chr1\t200\trs200\tA\tT\t25.0\tPASS\tIMPACT=MODERATE;DP=40
    chr1\t300\trs300\tC\tG\t35.0\tPASS\tIMPACT=HIGH;DP=30
    chr1\t400\trs400\tG\tA\t40.0\tPASS\tIMPACT=LOW;DP=60
    chr1\t500\trs500\tT\tC\t45.0\tPASS\tIMPACT=MODIFIER;DP=70
    chr2\t100\trs600\tA\tG\t50.0\tPASS\tIMPACT=HIGH;DP=80
    """

    /// VCF with both IMPACT and consequence annotations for biological high-impact token tests.
    private let biologicalImpactVCF = """
    ##fileformat=VCFv4.3
    ##INFO=<ID=IMPACT,Number=1,Type=String,Description="Variant impact">
    ##INFO=<ID=CSQ_Consequence,Number=1,Type=String,Description="VEP consequence">
    ##INFO=<ID=ANN_Consequence,Number=1,Type=String,Description="SnpEff consequence">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t100\trsBio1\tA\tG\t30.0\tPASS\tIMPACT=LOW;CSQ_Consequence=stop_gained
    chr1\t200\trsBio2\tA\tT\t25.0\tPASS\tIMPACT=HIGH;CSQ_Consequence=synonymous_variant
    chr1\t300\trsBio3\tC\tG\t35.0\tPASS\tIMPACT=LOW;CSQ_Consequence=missense_variant
    chr1\t400\trsBio4\tG\tA\t40.0\tPASS\tIMPACT=MODERATE;ANN_Consequence=frameshift_variant
    """

    func testWarmHighImpactCache() throws {
        let vcfURL = try createTempVCF(content: impactVCF, name: "impact.vcf")
        let dbURL = tempDir.appendingPathComponent("impact.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let db = try VariantDatabase(url: dbURL)

        // Since token tables are now built during import and loaded on open,
        // the high-impact cache should already be ready.
        XCTAssertTrue(db.highImpactCacheReady, "Cache should be ready after import (persistent table)")
    }

    func testHighImpactFilterUsesCache() throws {
        let vcfURL = try createTempVCF(content: impactVCF, name: "impact_filter.vcf")
        let dbURL = tempDir.appendingPathComponent("impact_filter.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        let db = try VariantDatabase(url: dbURL)

        // Warm the cache.
        let success = db.warmHighImpactCache(timeoutSeconds: 10)
        XCTAssertTrue(success)

        // Query with sole IMPACT=HIGH filter — should use the cached temp table.
        let impactFilter = VariantDatabase.InfoFilter(key: "IMPACT", op: .eq, value: "HIGH")
        let results = db.queryForTable(infoFilters: [impactFilter], limit: 100)

        // Should return the 3 HIGH-impact variants.
        XCTAssertEqual(results.count, 3, "Should find 3 HIGH-impact variants")
        let ids = Set(results.map(\.variantID))
        XCTAssertTrue(ids.contains("rs100"))
        XCTAssertTrue(ids.contains("rs300"))
        XCTAssertTrue(ids.contains("rs600"))
    }

    func testHighImpactFilterRegionScoped() throws {
        let vcfURL = try createTempVCF(content: impactVCF, name: "impact_region.vcf")
        let dbURL = tempDir.appendingPathComponent("impact_region.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let db = try VariantDatabase(url: dbURL)

        db.warmHighImpactCache(timeoutSeconds: 10)

        // Region query for chr1 only.
        let impactFilter = VariantDatabase.InfoFilter(key: "IMPACT", op: .eq, value: "HIGH")
        let results = db.queryForTableInRegion(
            chromosome: "chr1", start: 0, end: 1000,
            infoFilters: [impactFilter], limit: 100
        )

        XCTAssertEqual(results.count, 2, "Should find 2 HIGH-impact variants on chr1")
    }

    func testHighImpactCountUsesCache() throws {
        let vcfURL = try createTempVCF(content: impactVCF, name: "impact_count.vcf")
        let dbURL = tempDir.appendingPathComponent("impact_count.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let db = try VariantDatabase(url: dbURL)

        db.warmHighImpactCache(timeoutSeconds: 10)

        let impactFilter = VariantDatabase.InfoFilter(key: "IMPACT", op: .eq, value: "HIGH")
        let count = db.queryCountForTable(infoFilters: [impactFilter])
        XCTAssertEqual(count, 3, "Should count 3 HIGH-impact variants")

        let regionCount = db.queryCountInRegion(
            chromosome: "chr1", start: 0, end: 1000,
            infoFilters: [impactFilter]
        )
        XCTAssertEqual(regionCount, 2, "Should count 2 HIGH-impact variants in chr1 region")
    }

    func testHighImpactCacheWithNonImpactFilter() throws {
        let vcfURL = try createTempVCF(content: impactVCF, name: "impact_mixed.vcf")
        let dbURL = tempDir.appendingPathComponent("impact_mixed.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let db = try VariantDatabase(url: dbURL)

        db.warmHighImpactCache(timeoutSeconds: 10)

        // Mixed filter: IMPACT=HIGH + DP>=40 — should NOT use the temp table fast path,
        // should fall back to normal EAV query.
        let impactFilter = VariantDatabase.InfoFilter(key: "IMPACT", op: .eq, value: "HIGH")
        let dpFilter = VariantDatabase.InfoFilter(key: "DP", op: .gte, value: "40")
        let results = db.queryForTable(infoFilters: [impactFilter, dpFilter], limit: 100)

        // rs100 has IMPACT=HIGH;DP=50 ✓, rs300 has IMPACT=HIGH;DP=30 ✗, rs600 has IMPACT=HIGH;DP=80 ✓
        XCTAssertEqual(results.count, 2, "Mixed filter should return 2 results (normal EAV path)")
    }

    func testBiologicalHighImpactTokenTableCreated() throws {
        let vcfURL = try createTempVCF(content: biologicalImpactVCF, name: "bio_impact_token.vcf")
        let dbURL = tempDir.appendingPathComponent("bio_impact_token.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let db = try VariantDatabase(url: dbURL)

        XCTAssertNotNil(db.tokenCacheState["highImpactBiological"])
        XCTAssertTrue(db.tokenCacheState["highImpactBiological"]?.ready == true)
        XCTAssertEqual(db.tokenCacheState["highImpactBiological"]?.count, 3)
    }

    func testQueryWithBiologicalHighImpactToken() throws {
        let vcfURL = try createTempVCF(content: biologicalImpactVCF, name: "bio_impact_query.vcf")
        let dbURL = tempDir.appendingPathComponent("bio_impact_query.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let db = try VariantDatabase(url: dbURL)

        let results = db.queryForTable(activeTokens: Set(["highImpactBiological"]), limit: 100)
        XCTAssertEqual(results.count, 3)
        let ids = Set(results.map(\.variantID))
        XCTAssertEqual(ids, Set(["rsBio1", "rsBio2", "rsBio4"]))
    }

    func testBiologicalHighImpactTokenWithSkipVariantInfoImport() throws {
        let vcfURL = try createTempVCF(content: biologicalImpactVCF, name: "bio_impact_skipinfo.vcf")
        let dbURL = tempDir.appendingPathComponent("bio_impact_skipinfo.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            parseGenotypes: true,
            importProfile: .ultraLowMemory
        )
        let db = try VariantDatabase(url: dbURL)

        XCTAssertTrue(db.variantInfoSkipped)
        XCTAssertNotNil(db.tokenCacheState["highImpactBiological"])
        XCTAssertTrue(db.tokenCacheState["highImpactBiological"]?.ready == true)
        XCTAssertEqual(db.tokenCacheState["highImpactBiological"]?.count, 3)

        let results = db.queryForTable(activeTokens: Set(["highImpactBiological"]), limit: 100)
        let ids = Set(results.map(\.variantID))
        XCTAssertEqual(ids, Set(["rsBio1", "rsBio2", "rsBio4"]))
    }

    // MARK: - INFO Key Discovery Tests

    /// VCF for testing INFO key discovery from raw strings
    private let discoveryVCF = """
    ##fileformat=VCFv4.3
    ##contig=<ID=chr1,length=248956422>
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t100\trs100\tA\tG\t30.0\tPASS\tDP=50;AF=0.25;MQ=60
    chr1\t200\trs200\tATCG\tA\t25.0\tPASS\tDP=40;MQ=55
    chr1\t300\trs300\tA\tATCG\t35.0\tPASS\tDP=30;AF=0.01;VALIDATED
    chr1\t400\t.\tAT\tGC\t40.0\tPASS\tDP=60;AF=0.5;MQ=70;SOMATIC
    """

    func testDiscoverInfoKeysFromRawInfo() throws {
        // Import with ultraLowMemory so variant_info is skipped but raw INFO is stored.
        let vcfURL = try createTempVCF(content: discoveryVCF, name: "discover.vcf")
        let dbURL = tempDir.appendingPathComponent("discover.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )
        let db = try VariantDatabase(url: dbURL)

        let discovered = db.discoverInfoKeysFromRawInfo()
        let keyNames = Set(discovered.map(\.key))

        XCTAssertTrue(keyNames.contains("DP"), "Should discover DP key")
        XCTAssertTrue(keyNames.contains("AF"), "Should discover AF key")
        XCTAssertTrue(keyNames.contains("MQ"), "Should discover MQ key")
        XCTAssertTrue(keyNames.contains("VALIDATED"), "Should discover Flag-type key")

        // Check type inference
        let dpDef = discovered.first { $0.key == "DP" }
        XCTAssertEqual(dpDef?.type, "Integer", "DP should be inferred as Integer")

        let afDef = discovered.first { $0.key == "AF" }
        XCTAssertEqual(afDef?.type, "Float", "AF should be inferred as Float")

        let validatedDef = discovered.first { $0.key == "VALIDATED" }
        XCTAssertEqual(validatedDef?.type, "Flag", "Bare key should be inferred as Flag")
    }

    func testDiscoverInfoKeysCaching() throws {
        let vcfURL = try createTempVCF(content: discoveryVCF, name: "discover_cache.vcf")
        let dbURL = tempDir.appendingPathComponent("discover_cache.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )
        let db = try VariantDatabase(url: dbURL)

        let result1 = db.discoverInfoKeysFromRawInfo()
        let result2 = db.discoverInfoKeysFromRawInfo()
        // Should return same results (from cache)
        XCTAssertEqual(result1.count, result2.count, "Cached result should match initial")
    }

    func testDiscoverInfoKeysReturnsEmptyForStandardImport() throws {
        // Standard import has variant_info_defs populated, so discovery not needed.
        let (db, _) = try createDatabase(from: testVCF)
        _ = db.discoverInfoKeysFromRawInfo()
        // For a standard import, infoKeys() returns from variant_info_defs,
        // so discovery should still work by reading raw INFO, but the fallback
        // in infoKeys() should prefer variant_info_defs when present.
        let normalKeys = db.infoKeys()
        XCTAssertFalse(normalKeys.isEmpty, "Standard import should have INFO keys from defs table")
    }

    func testInfoKeysFallsBackToDiscoveredKeys() throws {
        let vcfURL = try createTempVCF(content: discoveryVCF, name: "discover_fallback.vcf")
        let dbURL = tempDir.appendingPathComponent("discover_fallback.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )
        let db = try VariantDatabase(url: dbURL)

        // For ultraLowMemory, infoKeys() should fall back to discovered keys.
        let keys = db.infoKeys()
        let keyNames = Set(keys.map(\.key))
        XCTAssertTrue(keyNames.contains("DP"), "infoKeys() should include discovered DP for skipVariantInfo DB")
        XCTAssertTrue(keyNames.contains("AF"), "infoKeys() should include discovered AF for skipVariantInfo DB")
    }

    // MARK: - SmartToken Cache Warming Tests

    func testWarmSmartTokenCaches() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))

        let state = db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // Should have at least the column-based tokens.
        XCTAssertNotNil(state["passOnly"], "Should have passOnly token")
        XCTAssertNotNil(state["snv"], "Should have snv token")
        XCTAssertNotNil(state["indel"], "Should have indel token")
        XCTAssertNotNil(state["qualityGE30"], "Should have qualityGE30 token")

        // Verify they're ready.
        XCTAssertTrue(state["passOnly"]!.ready, "passOnly should be ready")
        XCTAssertTrue(state["snv"]!.ready, "snv should be ready")
        XCTAssertTrue(state["qualityGE30"]!.ready, "qualityGE30 should be ready")
    }

    func testSmartTokenCacheCounts() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))

        let state = db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // testVCF has 4 PASS variants: rs100, rs200, rs400, rs1000
        XCTAssertEqual(state["passOnly"]?.count, 4, "Should have 4 PASS variants")

        // Variants with quality >= 30: rs100(30), rs300(35), rs400(40), rs500(45), rs1000(50) = 5
        XCTAssertEqual(state["qualityGE30"]?.count, 5, "Should have 5 qual>=30 variants")
    }

    func testSmartTokenCacheIncludesEAVTokensWhenAvailable() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))

        let state = db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // testVCF has DP and AF in INFO, so depth and rare tokens should appear.
        if infoKeys.contains("DP") {
            XCTAssertNotNil(state["depthGE10"], "Should have depthGE10 token with DP available")
            XCTAssertTrue(state["depthGE10"]!.ready)
        }

        if infoKeys.contains("AF") {
            XCTAssertNotNil(state["rareVariant"], "Should have rareVariant token with AF available")
            XCTAssertTrue(state["rareVariant"]!.ready)
        }
    }

    func testSmartTokenCacheSkipsEAVForSkipVariantInfoDB() throws {
        let vcfURL = try createTempVCF(content: testVCF, name: "skipinfo_tokens.vcf")
        let dbURL = tempDir.appendingPathComponent("skipinfo_tokens.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true, importProfile: .ultraLowMemory
        )
        let db = try VariantDatabase(url: dbURL)
        let infoKeys = Set(db.infoKeys().map(\.key))

        let state = db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // Column-based tokens should still work.
        XCTAssertNotNil(state["passOnly"])
        XCTAssertTrue(state["passOnly"]!.ready)

        // EAV-based tokens should NOT be present (variantInfoSkipped).
        XCTAssertNil(state["depthGE10"], "EAV token should not be created for skipVariantInfo DB")
        XCTAssertNil(state["rareVariant"], "EAV token should not be created for skipVariantInfo DB")
    }

    func testTokenCacheStateProperty() throws {
        let (db, _) = try createDatabase(from: testVCF)

        // Token tables are built during import and loaded on open,
        // so tokenCacheState should already be populated.
        XCTAssertFalse(db.tokenCacheState.isEmpty, "Cache state should be populated after import")
        XCTAssertNotNil(db.tokenCacheState["passOnly"])
        XCTAssertTrue(db.tokenCacheState["passOnly"]!.ready)
    }

    // MARK: - Token JOIN Query Tests

    func testQueryWithActiveTokenPassOnly() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))
        db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // Query with passOnly token active — should return only PASS variants.
        let results = db.queryForTable(activeTokens: Set(["passOnly"]), limit: 100)
        XCTAssertEqual(results.count, 4, "passOnly token should filter to 4 PASS variants")
        for r in results {
            XCTAssertEqual(r.filter, "PASS", "All results should have PASS filter")
        }
    }

    func testQueryWithActiveTokenQualityGE30() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))
        db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        let results = db.queryForTable(activeTokens: Set(["qualityGE30"]), limit: 100)
        XCTAssertEqual(results.count, 5, "qualityGE30 token should filter to 5 variants")
        for r in results {
            XCTAssertGreaterThanOrEqual(r.quality ?? 0, 30.0, "All results should have quality >= 30")
        }
    }

    func testQueryWithMultipleActiveTokens() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))
        db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // passOnly AND qualityGE30 — intersection.
        let results = db.queryForTable(activeTokens: Set(["passOnly", "qualityGE30"]), limit: 100)
        for r in results {
            XCTAssertEqual(r.filter, "PASS")
            XCTAssertGreaterThanOrEqual(r.quality ?? 0, 30.0)
        }
        // PASS variants with qual>=30: rs100(30), rs400(40), rs1000(50) = 3
        XCTAssertEqual(results.count, 3, "Intersection of passOnly and qualityGE30 should yield 3")
    }

    func testRegionQueryWithActiveToken() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))
        db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // Region query on chr1 with passOnly.
        let results = db.queryForTableInRegion(
            chromosome: "chr1", start: 0, end: 1000,
            activeTokens: Set(["passOnly"]),
            limit: 100
        )
        // chr1 PASS variants: rs100, rs200, rs400 = 3
        XCTAssertEqual(results.count, 3, "chr1 region with passOnly should yield 3")
        for r in results {
            XCTAssertEqual(r.filter, "PASS")
            XCTAssertEqual(r.chromosome, "chr1")
        }
    }

    func testCountQueryWithActiveToken() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))
        db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        let count = db.queryCountForTable(activeTokens: Set(["passOnly"]))
        XCTAssertEqual(count, 4, "Count with passOnly should be 4")

        let regionCount = db.queryCountInRegion(
            chromosome: "chr1", start: 0, end: 1000,
            activeTokens: Set(["passOnly"])
        )
        XCTAssertEqual(regionCount, 3, "Count in chr1 region with passOnly should be 3")
    }

    func testQueryWithTokenAndTypeFilter() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))
        db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // passOnly token + SNV type filter.
        let results = db.queryForTable(
            types: Set(["SNV"]),
            activeTokens: Set(["passOnly"]),
            limit: 100
        )
        for r in results {
            XCTAssertEqual(r.filter, "PASS")
            XCTAssertEqual(r.variantType, "SNV")
        }
    }

    func testQueryWithTokenAndInfoFilter() throws {
        let (db, _) = try createDatabase(from: testVCF)
        let infoKeys = Set(db.infoKeys().map(\.key))
        db.warmSmartTokenCaches(availableInfoKeys: infoKeys)

        // qualityGE30 token + DP>=50 info filter.
        let dpFilter = VariantDatabase.InfoFilter(key: "DP", op: .gte, value: "50")
        let results = db.queryForTable(
            infoFilters: [dpFilter],
            activeTokens: Set(["qualityGE30"]),
            limit: 100
        )
        for r in results {
            XCTAssertGreaterThanOrEqual(r.quality ?? 0, 30.0)
        }
    }

    func testQueryWithUnknownTokenFallsBack() throws {
        let (db, _) = try createDatabase(from: testVCF)
        // Querying with a token name that has no table should gracefully fall back
        // (unknown tokens are ignored, returning unfiltered results).
        let results = db.queryForTable(activeTokens: Set(["nonExistentToken"]), limit: 100)
        XCTAssertEqual(results.count, 7, "Unknown token should be ignored, returning all variants")
    }
}
