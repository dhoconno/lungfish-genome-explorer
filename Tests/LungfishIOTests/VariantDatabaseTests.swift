// VariantDatabaseTests.swift - Tests for VariantDatabase SQLite variant storage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
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

        XCTAssertNotNil(record.info)
        XCTAssertTrue(record.info?.contains("DP=50") ?? false)
        XCTAssertTrue(record.info?.contains("AF=0.25") ?? false)
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

    func testQueryCountForTable() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let totalCount = db.queryCountForTable()
        XCTAssertEqual(totalCount, 7)

        let snpCount = db.queryCountForTable(types: ["SNP"])
        XCTAssertTrue(snpCount >= 2)
        XCTAssertTrue(snpCount < totalCount)
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

    func testInfoKeysQuery() throws {
        let (db, _) = try createDatabase(from: testVCF)

        let keys = db.infoKeys()
        XCTAssertTrue(keys.count >= 3, "Should have at least DP, AF, END")

        // Verify descriptions are parsed
        let dpDef = keys.first(where: { $0.key == "DP" })
        XCTAssertEqual(dpDef?.description, "Total Depth")
    }

    func testBackwardCompatNoInfoTable() throws {
        // Create a minimal database without the variant_info tables (simulating legacy)
        let dbURL = tempDir.appendingPathComponent("legacy.db")
        var dbPtr: OpaquePointer?
        sqlite3_open(dbURL.path, &dbPtr)
        defer { sqlite3_close(dbPtr) }

        let schema = """
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
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            sample_name TEXT NOT NULL,
            PRIMARY KEY (variant_id, sample_name)
        );
        CREATE TABLE samples (name TEXT PRIMARY KEY, display_name TEXT, source_file TEXT, metadata TEXT);
        """
        sqlite3_exec(dbPtr, schema, nil, nil, nil)
        sqlite3_exec(dbPtr, "INSERT INTO variants VALUES (1, 'chr1', 100, 101, 'rs1', 'A', 'G', 'SNP', 30.0, 'PASS', 'DP=50', 0)", nil, nil, nil)
        sqlite3_close(dbPtr)
        dbPtr = nil

        // Open with VariantDatabase — should detect missing info table and not crash
        let db = try VariantDatabase(url: dbURL)
        let keys = db.infoKeys()
        XCTAssertTrue(keys.isEmpty, "Legacy DB should return empty infoKeys")

        // infoValues should fallback to parsing raw info string
        let info = db.infoValues(variantId: 1)
        XCTAssertEqual(info["DP"], "50", "Legacy fallback should parse raw INFO")
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
}
