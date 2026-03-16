// VariantDatabaseExtractionTests.swift - Tests for VariantDatabase.extractRegion
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishIO
@testable import LungfishCore

final class VariantDatabaseExtractionTests: XCTestCase {

    // MARK: - Test Data

    /// Multi-sample VCF spanning chr1:99-499 (0-based) with 3 samples
    private let multiSampleVCF = """
    ##fileformat=VCFv4.3
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
    ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
    ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE_A\tSAMPLE_B\tSAMPLE_C
    chr1\t100\trs100\tA\tG\t30.0\tPASS\tDP=100\tGT:DP\t0/1:30\t1/1:25\t0/0:40
    chr1\t250\trs250\tATCG\tA\t25.0\tPASS\tDP=90\tGT:DP\t0/0:20\t0/1:35\t./.:.
    chr1\t400\trs400\tC\tT\t50.0\tPASS\tDP=150\tGT:DP\t1/1:50\t0/1:45\t0/1:55
    chr1\t600\trs600\tG\tA\t45.0\tPASS\tDP=80\tGT:DP\t0/1:30\t0/0:25\t1/1:35
    chr2\t100\trs2_100\tC\tT\t40.0\tPASS\tDP=60\tGT:DP\t0/1:20\t1/1:30\t0/0:25
    """

    /// VCF with no samples (header-only variant records)
    private let noSampleVCF = """
    ##fileformat=VCFv4.3
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t100\trs100\tA\tG\t30.0\tPASS\tDP=100
    chr1\t300\trs300\tC\tT\t50.0\tPASS\tDP=150
    """

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantExtractionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func createDatabase(from vcfContent: String, name: String = "source.db") throws -> VariantDatabase {
        let vcfURL = tempDir.appendingPathComponent("input.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent(name)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        return try VariantDatabase(url: dbURL)
    }

    // MARK: - Basic Extraction

    func testExtractRegionReturnsCorrectCount() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("extracted.db")

        // chr1:50-500 should capture rs100 (pos 99), rs250 (pos 249), rs400 (pos 399)
        // VCF positions are 1-based, stored as 0-based: 99, 249, 399, 599
        let count = try db.extractRegion(
            chromosome: "chr1", start: 50, end: 500,
            outputURL: outURL
        )
        XCTAssertEqual(count, 3, "Should extract 3 variants from chr1:50-500")
    }

    func testExtractRegionCreatesValidDatabase() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("extracted.db")

        try db.extractRegion(chromosome: "chr1", start: 50, end: 500, outputURL: outURL)

        // Open the extracted database and verify it's queryable
        let extractedDB = try VariantDatabase(url: outURL)
        let allVariants = extractedDB.query(chromosome: "chr1", start: 0, end: 500)
        XCTAssertEqual(allVariants.count, 3)
    }

    func testExtractRegionShiftsCoordinates() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("extracted.db")

        // Extract chr1:99-500, so position 99 becomes 0, 249 becomes 150, 399 becomes 300
        try db.extractRegion(chromosome: "chr1", start: 99, end: 500, outputURL: outURL)

        let extractedDB = try VariantDatabase(url: outURL)
        let variants = extractedDB.query(chromosome: "chr1", start: 0, end: 500)

        let positions = variants.map { $0.position }.sorted()
        XCTAssertEqual(positions, [0, 150, 300], "Positions should be shifted by -99")
    }

    func testExtractRegionRenamesChromosome() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("extracted.db")

        try db.extractRegion(
            chromosome: "chr1", start: 50, end: 500,
            outputURL: outURL,
            newChromosome: "extracted_seq"
        )

        let extractedDB = try VariantDatabase(url: outURL)
        // Query with old name should return nothing
        let oldNameResults = extractedDB.query(chromosome: "chr1", start: 0, end: 500)
        XCTAssertTrue(oldNameResults.isEmpty, "Old chromosome name should have no results")

        // Query with new name should return all
        let newNameResults = extractedDB.query(chromosome: "extracted_seq", start: 0, end: 500)
        XCTAssertEqual(newNameResults.count, 3)
    }

    func testExtractRegionEmptyRegionReturnsZero() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("extracted.db")

        // Region with no variants
        let count = try db.extractRegion(
            chromosome: "chr1", start: 700, end: 800,
            outputURL: outURL
        )
        XCTAssertEqual(count, 0, "Should return 0 for region with no variants")
    }

    func testExtractRegionDifferentChromosome() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("extracted.db")

        let count = try db.extractRegion(
            chromosome: "chr2", start: 0, end: 200,
            outputURL: outURL
        )
        XCTAssertEqual(count, 1, "Should extract 1 variant from chr2:0-200")
    }

    func testExtractRegionUsesChromosomeAliases() throws {
        let aliasVCF = """
        ##fileformat=VCFv4.3
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE_A
        7\t100\trs100\tA\tG\t30.0\tPASS\t.\tGT\t0/1
        7\t240\trs240\tC\tT\t40.0\tPASS\t.\tGT\t1/1
        """

        let db = try createDatabase(from: aliasVCF, name: "alias_source.db")
        let outURL = tempDir.appendingPathComponent("alias_extracted.db")

        let count = try db.extractRegion(
            chromosome: "NC_041760.1",
            chromosomeAliases: ["7"],
            start: 50,
            end: 300,
            outputURL: outURL
        )
        XCTAssertEqual(count, 2, "Alias fallback should extract variants stored under chromosome '7'")

        let extractedDB = try VariantDatabase(url: outURL)
        let extracted = extractedDB.query(chromosome: "NC_041760.1", start: 0, end: 260)
        XCTAssertEqual(extracted.count, 2, "Extracted variants should be rewritten to the requested chromosome name")
    }

    // MARK: - Sample Filtering

    func testExtractRegionWithSampleFilter() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("filtered.db")

        try db.extractRegion(
            chromosome: "chr1", start: 50, end: 500,
            outputURL: outURL,
            sampleFilter: Set(["SAMPLE_A", "SAMPLE_B"])
        )

        let extractedDB = try VariantDatabase(url: outURL)
        let samples = extractedDB.sampleNames()
        XCTAssertEqual(Set(samples), Set(["SAMPLE_A", "SAMPLE_B"]),
                       "Only filtered samples should appear")
        XCTAssertFalse(samples.contains("SAMPLE_C"),
                       "SAMPLE_C should be excluded")
    }

    func testExtractRegionSampleCountReflectsFilteredGenotypes() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("sample_count_filtered.db")

        // Keep only SAMPLE_A. sample_count should match genotype rows that survive filtering.
        try db.extractRegion(
            chromosome: "chr1", start: 50, end: 500,
            outputURL: outURL,
            sampleFilter: Set(["SAMPLE_A"])
        )

        let extractedDB = try VariantDatabase(url: outURL)
        let variants = extractedDB.query(chromosome: "chr1", start: 0, end: 500)
        XCTAssertEqual(variants.count, 3)
        for variant in variants {
            guard let variantID = variant.id else {
                XCTFail("Expected extracted variants to have persistent IDs")
                continue
            }
            let genotypeRows = extractedDB.genotypes(forVariantId: variantID)
            XCTAssertEqual(variant.sampleCount, genotypeRows.count,
                           "sample_count should match persisted genotype rows after filtering")
        }
    }

    func testExtractRegionWithSingleSampleFilter() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("single.db")

        try db.extractRegion(
            chromosome: "chr1", start: 50, end: 500,
            outputURL: outURL,
            sampleFilter: Set(["SAMPLE_C"])
        )

        let extractedDB = try VariantDatabase(url: outURL)
        let samples = extractedDB.sampleNames()
        XCTAssertEqual(samples, ["SAMPLE_C"])
    }

    func testExtractRegionNilSampleFilterIncludesAll() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("all.db")

        try db.extractRegion(
            chromosome: "chr1", start: 50, end: 500,
            outputURL: outURL,
            sampleFilter: nil
        )

        let extractedDB = try VariantDatabase(url: outURL)
        let samples = extractedDB.sampleNames()
        XCTAssertEqual(Set(samples), Set(["SAMPLE_A", "SAMPLE_B", "SAMPLE_C"]),
                       "Nil filter should include all samples")
    }

    func testExtractRegionNoSampleVCF() throws {
        let db = try createDatabase(from: noSampleVCF, name: "nosample.db")
        let outURL = tempDir.appendingPathComponent("nosample_extract.db")

        let count = try db.extractRegion(
            chromosome: "chr1", start: 0, end: 400,
            outputURL: outURL
        )
        XCTAssertEqual(count, 2, "Should extract 2 variants without samples")

        let extractedDB = try VariantDatabase(url: outURL)
        let samples = extractedDB.sampleNames()
        // No-sample VCFs now create a synthetic sample for source-file tracking
        XCTAssertEqual(samples.count, 1, "No-sample VCF should have synthetic sample")
    }

    // MARK: - Genotype Preservation

    func testExtractRegionPreservesGenotypes() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("genotypes.db")

        try db.extractRegion(
            chromosome: "chr1", start: 50, end: 200,
            outputURL: outURL
        )

        let extractedDB = try VariantDatabase(url: outURL)
        let variants = extractedDB.query(chromosome: "chr1", start: 0, end: 200)
        XCTAssertEqual(variants.count, 1, "Should have 1 variant in region")

        // Check genotypes are preserved for the extracted variant.
        // Note: homozygous reference (0/0) genotypes may be omitted by the importer.
        if let variantId = variants.first?.id {
            let genotypes = extractedDB.genotypes(forVariantId: variantId)
            XCTAssertGreaterThanOrEqual(genotypes.count, 2,
                                        "At least non-ref genotypes should be preserved")
            let sampleNames = Set(genotypes.map { $0.sampleName })
            XCTAssertTrue(sampleNames.contains("SAMPLE_A"))
            XCTAssertTrue(sampleNames.contains("SAMPLE_B"))
        }
    }

    // MARK: - Metadata

    func testExtractRegionWritesMetadata() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("meta.db")

        try db.extractRegion(
            chromosome: "chr1", start: 100, end: 400,
            outputURL: outURL
        )

        // Check db_metadata table has extraction info
        var destDB: OpaquePointer?
        guard sqlite3_open(outURL.path, &destDB) == SQLITE_OK else {
            XCTFail("Cannot open extracted database")
            return
        }
        defer { sqlite3_close(destDB) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM db_metadata WHERE key = 'extracted_from_region'"
        guard sqlite3_prepare_v2(destDB, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("Cannot prepare metadata query")
            return
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let value = String(cString: sqlite3_column_text(stmt, 0))
            XCTAssertEqual(value, "chr1:100-400")
        } else {
            XCTFail("extracted_from_region metadata not found")
        }
    }

    func testExtractRegionPreservesSampleMetadataAndSourceFile() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let writableDB = try VariantDatabase(url: db.databaseURL, readWrite: true)
        try writableDB.updateSampleMetadata(
            name: "SAMPLE_A",
            metadata: ["Country": "USA", "Phenotype": "Case"]
        )
        let outURL = tempDir.appendingPathComponent("sample_meta.db")

        try db.extractRegion(
            chromosome: "chr1", start: 50, end: 200,
            outputURL: outURL,
            sampleFilter: Set(["SAMPLE_A"])
        )

        let extractedDB = try VariantDatabase(url: outURL)
        let metadata = extractedDB.sampleMetadata(name: "SAMPLE_A")
        XCTAssertEqual(metadata["Country"], "USA")
        XCTAssertEqual(metadata["Phenotype"], "Case")
        XCTAssertEqual(extractedDB.allSourceFiles()["SAMPLE_A"], "input.vcf")
    }

    func testExtractRegionOverwritesExisting() throws {
        let db = try createDatabase(from: multiSampleVCF)
        let outURL = tempDir.appendingPathComponent("overwrite.db")

        // First extraction
        try db.extractRegion(chromosome: "chr1", start: 50, end: 200, outputURL: outURL)
        let count1 = try VariantDatabase(url: outURL).query(chromosome: "chr1", start: 0, end: 500).count
        XCTAssertEqual(count1, 1)

        // Second extraction to same URL — should overwrite
        try db.extractRegion(chromosome: "chr1", start: 50, end: 500, outputURL: outURL)
        let count2 = try VariantDatabase(url: outURL).query(chromosome: "chr1", start: 0, end: 500).count
        XCTAssertEqual(count2, 3, "Second extraction should overwrite first")
    }
}
