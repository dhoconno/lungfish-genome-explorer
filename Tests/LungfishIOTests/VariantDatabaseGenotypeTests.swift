// VariantDatabaseGenotypeTests.swift - Tests for v2 genotype storage, sample metadata, and queries
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishIO
@testable import LungfishCore

final class VariantDatabaseGenotypeTests: XCTestCase {

    // MARK: - Test Data

    /// Multi-sample VCF with 3 samples and various genotype data
    private let multiSampleVCF = """
    ##fileformat=VCFv4.3
    ##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
    ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
    ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">
    ##FORMAT=<ID=GQ,Number=1,Type=Integer,Description="Genotype quality">
    ##FORMAT=<ID=AD,Number=R,Type=Integer,Description="Allelic depths">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE_A\tSAMPLE_B\tSAMPLE_C
    chr1\t100\trs100\tA\tG\t30.0\tPASS\tDP=100\tGT:DP:GQ:AD\t0/1:30:99:15,15\t1/1:25:80:0,25\t0/0:40:95:40,0
    chr1\t200\trs200\tATCG\tA\t25.0\tPASS\tDP=90\tGT:DP:GQ\t0/0:20:60\t0/1:35:90\t./.
    chr1\t500\trs500\tC\tT\t50.0\tPASS\tDP=150\tGT:DP:GQ:AD\t1|1:50:99:0,50\t0|1:45:88:20,25\t0/1:55:99:30,25
    chr2\t1000\trs1000\tG\tA\t45.0\tPASS\tDP=80\tGT:DP\t0/1:30\t0/0:25\t1/1:35
    """

    /// VCF with phased genotypes
    private let phasedVCF = """
    ##fileformat=VCFv4.3
    ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE1\tSAMPLE2
    chr1\t100\trs1\tA\tG\t50.0\tPASS\t.\tGT\t0|1\t1|0
    chr1\t200\trs2\tC\tT\t45.0\tPASS\t.\tGT\t1|1\t0|0
    """

    /// VCF with missing genotypes and edge cases
    private let edgeCaseVCF = """
    ##fileformat=VCFv4.3
    ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
    ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2\tS3
    chr1\t100\t.\tA\tG\t30.0\tPASS\t.\tGT:DP\t./.:.\t.|.:.	0/1:20
    chr1\t200\t.\tC\tT\t40.0\tPASS\t.\tGT\t.\t0/1\t1/1
    """

    /// Single-sample VCF (no genotypes beyond column 9)
    private let singleSampleVCF = """
    ##fileformat=VCFv4.3
    ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tNAHQ01
    chr1\t100\trs1\tA\tG\t50.0\tPASS\t.\tGT\t0/1
    chr1\t200\trs2\tC\tT\t45.0\tPASS\t.\tGT\t1/1
    chr1\t300\trs3\tG\tA\t30.0\tPASS\t.\tGT\t0/0
    """

    /// VCF with no sample columns (header only has 8 columns)
    private let noSampleVCF = """
    ##fileformat=VCFv4.3
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
    chr1\t100\trs1\tA\tG\t50.0\tPASS\tDP=30
    chr1\t200\trs2\tC\tT\t45.0\tPASS\tDP=25
    """

    /// VCF where FORMAT omits GT (sample_count should still reflect non-empty sample payloads)
    private let noGTFormatVCF = """
    ##fileformat=VCFv4.3
    ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2\tS3
    chr1\t100\trsNoGT\tA\tG\t60.0\tPASS\t.\tDP\t12\t.\t22
    """

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeTests_\(UUID().uuidString)")
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

    private func createDatabase(from vcfContent: String, parseGenotypes: Bool = true) throws -> (VariantDatabase, URL) {
        let vcfURL = try createTempVCF(content: vcfContent)
        let dbURL = tempDir.appendingPathComponent("test.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: parseGenotypes
        )
        let db = try VariantDatabase(url: dbURL)
        return (db, dbURL)
    }

    private func createWritableDatabase(from vcfContent: String) throws -> (VariantDatabase, URL) {
        let vcfURL = try createTempVCF(content: vcfContent)
        let dbURL = tempDir.appendingPathComponent("test.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let db = try VariantDatabase(url: dbURL, readWrite: true)
        return (db, dbURL)
    }

    // MARK: - Sample Parsing

    func testSampleNamesFromMultiSampleVCF() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)
        let names = db.sampleNames()
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains("SAMPLE_A"))
        XCTAssertTrue(names.contains("SAMPLE_B"))
        XCTAssertTrue(names.contains("SAMPLE_C"))
    }

    func testSampleCount() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)
        XCTAssertEqual(db.sampleCount(), 3)
    }

    func testSingleSampleVCF() throws {
        let (db, _) = try createDatabase(from: singleSampleVCF)
        let names = db.sampleNames()
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names.first, "NAHQ01")
    }

    func testNoSampleVCF() throws {
        let (db, _) = try createDatabase(from: noSampleVCF)
        XCTAssertEqual(db.sampleCount(), 0)
        XCTAssertTrue(db.sampleNames().isEmpty)
    }

    // MARK: - Genotype Storage & Retrieval

    func testGenotypesForVariant() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        // rs100 at chr1:99 (0-based)
        let variants = db.query(chromosome: "chr1", start: 99, end: 100)
        XCTAssertEqual(variants.count, 1)
        let variant = try XCTUnwrap(variants.first)
        XCTAssertNotNil(variant.id)

        let genotypes = db.genotypes(forVariantId: variant.id!)
        // v3: hom-ref genotypes (SAMPLE_C=0/0) are omitted
        XCTAssertEqual(genotypes.count, 2, "Should have genotype for non-hom-ref samples only")

        let sampleA = genotypes.first { $0.sampleName == "SAMPLE_A" }
        XCTAssertNotNil(sampleA)
        XCTAssertEqual(sampleA?.genotype, "0/1")
        XCTAssertEqual(sampleA?.allele1, 0)
        XCTAssertEqual(sampleA?.allele2, 1)
        XCTAssertFalse(sampleA?.isPhased ?? true)
        XCTAssertEqual(sampleA?.depth, 30)
        XCTAssertEqual(sampleA?.genotypeQuality, 99)
        XCTAssertEqual(sampleA?.alleleDepths, "15,15")
        XCTAssertEqual(sampleA?.genotypeCall, .het)

        let sampleB = genotypes.first { $0.sampleName == "SAMPLE_B" }
        XCTAssertEqual(sampleB?.genotype, "1/1")
        XCTAssertEqual(sampleB?.allele1, 1)
        XCTAssertEqual(sampleB?.allele2, 1)
        XCTAssertEqual(sampleB?.depth, 25)
        XCTAssertEqual(sampleB?.genotypeQuality, 80)
        XCTAssertEqual(sampleB?.alleleDepths, "0,25")
        XCTAssertEqual(sampleB?.genotypeCall, .homAlt)

        // SAMPLE_C (0/0) is not stored — inferred as hom-ref from absence
        let sampleC = genotypes.first { $0.sampleName == "SAMPLE_C" }
        XCTAssertNil(sampleC, "Hom-ref genotypes should not be stored in v3")
    }

    func testMissingGenotypesNotStored() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        // rs200: SAMPLE_A=0/0 (hom-ref, omitted), SAMPLE_B=0/1, SAMPLE_C=./.
        let variants = db.query(chromosome: "chr1", start: 199, end: 200)
        let variant = try XCTUnwrap(variants.first)
        let genotypes = db.genotypes(forVariantId: variant.id!)

        // v3: Only SAMPLE_B (0/1) stored. SAMPLE_A (0/0) omitted, SAMPLE_C (./.) skipped.
        XCTAssertEqual(genotypes.count, 1, "Only non-hom-ref called genotypes should be stored")
        let sampleNames = genotypes.map(\.sampleName)
        XCTAssertFalse(sampleNames.contains("SAMPLE_A"), "Hom-ref should not be stored")
        XCTAssertTrue(sampleNames.contains("SAMPLE_B"))
        XCTAssertFalse(sampleNames.contains("SAMPLE_C"))
    }

    func testEdgeCaseMissingGenotypes() throws {
        let (db, _) = try createDatabase(from: edgeCaseVCF)

        // First variant: S1="./.:.", S2=".|.:.", S3="0/1:20"
        // No-call genotypes are omitted in v3, so only called non-hom-ref rows are stored.
        let variants = db.query(chromosome: "chr1", start: 99, end: 100)
        let variant = try XCTUnwrap(variants.first)
        let genotypes = db.genotypes(forVariantId: variant.id!)

        XCTAssertEqual(genotypes.count, 1, "Only S3 should be stored as a called non-hom-ref genotype")

        let s3 = genotypes.first { $0.sampleName == "S3" }
        XCTAssertEqual(s3?.genotypeCall, .het)
        XCTAssertEqual(s3?.depth, 20)
    }

    func testSingleDotMissingGenotype() throws {
        let (db, _) = try createDatabase(from: edgeCaseVCF)

        // Second variant: S1=".", S2="0/1", S3="1/1"
        let variants = db.query(chromosome: "chr1", start: 199, end: 200)
        let variant = try XCTUnwrap(variants.first)
        let genotypes = db.genotypes(forVariantId: variant.id!)

        XCTAssertEqual(genotypes.count, 2, "Single '.' should be skipped")
        let names = genotypes.map(\.sampleName)
        XCTAssertFalse(names.contains("S1"))
        XCTAssertTrue(names.contains("S2"))
        XCTAssertTrue(names.contains("S3"))
    }

    // MARK: - Phased Genotypes

    func testPhasedGenotypes() throws {
        let (db, _) = try createDatabase(from: phasedVCF)

        let variants = db.query(chromosome: "chr1", start: 99, end: 100)
        let variant = try XCTUnwrap(variants.first)
        let genotypes = db.genotypes(forVariantId: variant.id!)

        let s1 = genotypes.first { $0.sampleName == "SAMPLE1" }
        XCTAssertNotNil(s1)
        XCTAssertEqual(s1?.genotype, "0|1")
        XCTAssertTrue(s1?.isPhased ?? false, "| separator should be phased")
        XCTAssertEqual(s1?.allele1, 0)
        XCTAssertEqual(s1?.allele2, 1)
        XCTAssertEqual(s1?.genotypeCall, .het)

        let s2 = genotypes.first { $0.sampleName == "SAMPLE2" }
        XCTAssertEqual(s2?.genotype, "1|0")
        XCTAssertTrue(s2?.isPhased ?? false)
        XCTAssertEqual(s2?.allele1, 1)
        XCTAssertEqual(s2?.allele2, 0)
        XCTAssertEqual(s2?.genotypeCall, .het)
    }

    func testPhasedHomozygous() throws {
        let (db, _) = try createDatabase(from: phasedVCF)

        // rs2: SAMPLE1=1|1, SAMPLE2=0|0
        let variants = db.query(chromosome: "chr1", start: 199, end: 200)
        let variant = try XCTUnwrap(variants.first)
        let genotypes = db.genotypes(forVariantId: variant.id!)

        // v3: SAMPLE2 (0|0) is hom-ref → not stored
        XCTAssertEqual(genotypes.count, 1, "Only non-hom-ref genotypes stored")

        let s1 = genotypes.first { $0.sampleName == "SAMPLE1" }
        XCTAssertEqual(s1?.genotypeCall, .homAlt)
        XCTAssertTrue(s1?.isPhased ?? false)

        // SAMPLE2 (0|0) inferred as hom-ref from absence
        let s2 = genotypes.first { $0.sampleName == "SAMPLE2" }
        XCTAssertNil(s2, "Hom-ref genotype should not be stored")
    }

    // MARK: - Sample Count on Variant Records

    func testVariantSampleCount() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        // rs100: all 3 samples have calls
        let v1 = db.query(chromosome: "chr1", start: 99, end: 100)
        XCTAssertEqual(v1.first?.sampleCount, 3)

        // rs200: SAMPLE_C is ./. → 2 non-missing
        let v2 = db.query(chromosome: "chr1", start: 199, end: 200)
        XCTAssertEqual(v2.first?.sampleCount, 2)
    }

    func testNoSampleVCFHasZeroSampleCount() throws {
        let (db, _) = try createDatabase(from: noSampleVCF)
        let variants = db.query(chromosome: "chr1", start: 0, end: 1000)
        for v in variants {
            XCTAssertEqual(v.sampleCount, 0)
        }
    }

    func testSampleCountWhenFormatHasNoGT() throws {
        let (db, _) = try createDatabase(from: noGTFormatVCF)
        let variants = db.query(chromosome: "chr1", start: 99, end: 100)
        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants.first?.sampleCount, 2, "S1 and S3 should count as called when FORMAT has no GT")
        let variant = try XCTUnwrap(variants.first)
        let genotypes = db.genotypes(forVariantId: try XCTUnwrap(variant.id))
        XCTAssertTrue(genotypes.isEmpty, "Without GT, no genotype rows should be inserted")
    }

    // MARK: - Variant Row ID

    func testVariantHasAutoIncrementID() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)
        let variants = db.query(chromosome: "chr1", start: 0, end: 10000)

        for v in variants {
            XCTAssertNotNil(v.id, "V2 schema should provide auto-increment ID")
        }

        // IDs should be unique
        let ids = variants.compactMap(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "IDs should be unique")
    }

    // MARK: - Genotype Queries by Sample and Region

    func testGenotypesForSampleInRegion() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        // Query SAMPLE_A genotypes in chr1:0-1000 (all chr1 variants)
        let genotypes = db.genotypes(forSample: "SAMPLE_A", chromosome: "chr1", start: 0, end: 1000)

        // rs100 (0/1), rs500 (1|1) = 2 records. rs200 (0/0) is hom-ref → not stored.
        XCTAssertEqual(genotypes.count, 2)

        // Verify they're ordered by position
        // The genotypes should correspond to variant positions 99, 199, 499
        XCTAssertTrue(genotypes.allSatisfy { $0.sampleName == "SAMPLE_A" })
    }

    func testGenotypesForSampleInNarrowRegion() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        // Only query around rs100
        let genotypes = db.genotypes(forSample: "SAMPLE_A", chromosome: "chr1", start: 90, end: 110)
        XCTAssertEqual(genotypes.count, 1)
        XCTAssertEqual(genotypes.first?.genotype, "0/1")
    }

    func testGenotypesForNonexistentSample() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)
        let genotypes = db.genotypes(forSample: "NONEXISTENT", chromosome: "chr1", start: 0, end: 10000)
        XCTAssertTrue(genotypes.isEmpty)
    }

    func testGenotypesForSampleOnDifferentChromosome() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        let genotypes = db.genotypes(forSample: "SAMPLE_A", chromosome: "chr2", start: 0, end: 10000)
        XCTAssertEqual(genotypes.count, 1, "Should find 1 genotype on chr2")
        XCTAssertEqual(genotypes.first?.genotype, "0/1")
    }

    // MARK: - genotypesInRegion (grouped query)

    func testGenotypesInRegion() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        let results = db.genotypesInRegion(chromosome: "chr1", start: 0, end: 1000)
        // chr1 has 3 variants: rs100, rs200, rs500
        XCTAssertEqual(results.count, 3)

        for (variant, genotypes) in results {
            XCTAssertNotNil(variant.id)
            XCTAssertFalse(genotypes.isEmpty, "Each variant should have at least 1 genotype")
        }

        // v3: rs100 has 2 non-hom-ref genotypes (SAMPLE_C=0/0 omitted)
        // rs200 has 1 non-hom-ref genotype (SAMPLE_A=0/0 omitted, SAMPLE_C=./. skipped)
        let rs100 = results.first { $0.variant.variantID == "rs100" }
        XCTAssertEqual(rs100?.genotypes.count, 2)

        let rs200 = results.first { $0.variant.variantID == "rs200" }
        XCTAssertEqual(rs200?.genotypes.count, 1)
    }

    func testGenotypesInRegionEmptyResult() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)
        let results = db.genotypesInRegion(chromosome: "chr1", start: 5000, end: 6000)
        XCTAssertTrue(results.isEmpty)
    }

    func testGenotypesInRegionDoesNotTruncateHighSampleVariant() throws {
        var header = "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT"
        var sampleCols: [String] = []
        for i in 1...400 {
            let name = "S\(i)"
            sampleCols.append(name)
            header += "\t\(name)"
        }
        let sampleData = Array(repeating: "0/1", count: 400).joined(separator: "\t")
        let vcf = """
        ##fileformat=VCFv4.3
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        \(header)
        chr1\t100\trsHuge\tA\tG\t30\tPASS\t.\tGT\t\(sampleData)
        """

        let (db, _) = try createDatabase(from: vcf)
        let results = db.genotypesInRegion(chromosome: "chr1", start: 0, end: 1000, limit: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].variant.variantID, "rsHuge")
        XCTAssertEqual(results[0].genotypes.count, 400, "All sample genotypes should be present for the returned variant")
    }

    // MARK: - GenotypeCall Classification

    func testGenotypeCallHomRef() {
        let record = GenotypeRecord(
            variantRowId: 1, sampleName: "s1", genotype: "0/0",
            allele1: 0, allele2: 0, isPhased: false,
            depth: nil, genotypeQuality: nil, alleleDepths: nil, rawFields: nil
        )
        XCTAssertEqual(record.genotypeCall, .homRef)
    }

    func testGenotypeCallHet() {
        let record = GenotypeRecord(
            variantRowId: 1, sampleName: "s1", genotype: "0/1",
            allele1: 0, allele2: 1, isPhased: false,
            depth: nil, genotypeQuality: nil, alleleDepths: nil, rawFields: nil
        )
        XCTAssertEqual(record.genotypeCall, .het)
    }

    func testGenotypeCallHetReversed() {
        let record = GenotypeRecord(
            variantRowId: 1, sampleName: "s1", genotype: "1/0",
            allele1: 1, allele2: 0, isPhased: false,
            depth: nil, genotypeQuality: nil, alleleDepths: nil, rawFields: nil
        )
        XCTAssertEqual(record.genotypeCall, .het)
    }

    func testGenotypeCallHomAlt() {
        let record = GenotypeRecord(
            variantRowId: 1, sampleName: "s1", genotype: "1/1",
            allele1: 1, allele2: 1, isPhased: false,
            depth: nil, genotypeQuality: nil, alleleDepths: nil, rawFields: nil
        )
        XCTAssertEqual(record.genotypeCall, .homAlt)
    }

    func testGenotypeCallHomAltHigherAllele() {
        let record = GenotypeRecord(
            variantRowId: 1, sampleName: "s1", genotype: "2/2",
            allele1: 2, allele2: 2, isPhased: false,
            depth: nil, genotypeQuality: nil, alleleDepths: nil, rawFields: nil
        )
        XCTAssertEqual(record.genotypeCall, .homAlt)
    }

    func testGenotypeCallNoCallBothMissing() {
        let record = GenotypeRecord(
            variantRowId: 1, sampleName: "s1", genotype: "./.",
            allele1: -1, allele2: -1, isPhased: false,
            depth: nil, genotypeQuality: nil, alleleDepths: nil, rawFields: nil
        )
        XCTAssertEqual(record.genotypeCall, .noCall)
    }

    func testGenotypeCallNoCallOneMissing() {
        let record = GenotypeRecord(
            variantRowId: 1, sampleName: "s1", genotype: "./1",
            allele1: -1, allele2: 1, isPhased: false,
            depth: nil, genotypeQuality: nil, alleleDepths: nil, rawFields: nil
        )
        XCTAssertEqual(record.genotypeCall, .noCall, "If either allele is missing, should be noCall")
    }

    // MARK: - GenotypeCall Colors

    func testGenotypeCallColors() {
        // Verify IGV-compatible color values
        let homRef = GenotypeCall.homRef.color
        XCTAssertEqual(homRef.r, 0.784, accuracy: 0.01)
        XCTAssertEqual(homRef.g, 0.784, accuracy: 0.01)

        let het = GenotypeCall.het.color
        XCTAssertEqual(het.r, 0.133, accuracy: 0.01)
        XCTAssertEqual(het.b, 0.992, accuracy: 0.01)

        let homAlt = GenotypeCall.homAlt.color
        XCTAssertEqual(homAlt.g, 0.973, accuracy: 0.01)
        XCTAssertEqual(homAlt.b, 0.996, accuracy: 0.01)

        let noCall = GenotypeCall.noCall.color
        XCTAssertEqual(noCall.r, 0.980, accuracy: 0.01)
    }

    // MARK: - Raw Fields (v3: not stored)

    func testRawFieldsNilInV3() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        let variants = db.query(chromosome: "chr1", start: 99, end: 100)
        let variant = try XCTUnwrap(variants.first)
        let genotypes = db.genotypes(forVariantId: variant.id!)

        let sampleA = genotypes.first { $0.sampleName == "SAMPLE_A" }
        XCTAssertNotNil(sampleA, "SAMPLE_A (0/1 het) should be stored")
        // v3: raw_fields is not populated (individual columns GT/DP/GQ/AD are sufficient)
        XCTAssertNil(sampleA?.rawFields, "v3 databases should not store raw_fields")

        // Individual fields should still be available
        XCTAssertEqual(sampleA?.genotype, "0/1")
        XCTAssertEqual(sampleA?.depth, 30)
        XCTAssertEqual(sampleA?.genotypeQuality, 99)
        XCTAssertEqual(sampleA?.alleleDepths, "15,15")
    }

    // MARK: - parseGenotypes flag

    func testParseGenotypesDisabled() throws {
        let vcfURL = try createTempVCF(content: multiSampleVCF)
        let dbURL = tempDir.appendingPathComponent("no_genotypes.db")
        let count = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL, parseGenotypes: false
        )
        XCTAssertEqual(count, 4, "Should still insert variants")

        let db = try VariantDatabase(url: dbURL)
        // Samples table is still created from the header, but genotypes are not stored
        let names = db.sampleNames()
        XCTAssertEqual(names.count, 3, "Sample names from header should still be inserted")

        // But genotype records should be empty (parseGenotypes was false)
        let variants = db.query(chromosome: "chr1", start: 0, end: 10000)
        for v in variants {
            let gts = db.genotypes(forVariantId: v.id!)
            XCTAssertTrue(gts.isEmpty, "Genotypes should not be stored when parseGenotypes is false")
        }
    }

    // MARK: - Progress Handler

    func testProgressHandlerCalled() throws {
        let vcfURL = try createTempVCF(content: multiSampleVCF)
        let dbURL = tempDir.appendingPathComponent("progress.db")

        // Use nonisolated(unsafe) to capture in @Sendable closure (test-only, single-threaded)
        nonisolated(unsafe) var progressValues: [Double] = []
        nonisolated(unsafe) var progressMessages: [String] = []

        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: dbURL,
            parseGenotypes: true,
            progressHandler: { fraction, message in
                progressValues.append(fraction)
                progressMessages.append(message)
            }
        )

        XCTAssertFalse(progressValues.isEmpty, "Progress handler should be called")
        XCTAssertEqual(progressValues.first ?? -1, 0.05, accuracy: 0.01, "First progress should be ~5%")
        XCTAssertEqual(progressValues.last ?? -1, 1.0, accuracy: 0.01, "Final progress should be 100%")
        XCTAssertTrue(progressMessages.last?.contains("Done") ?? false)
        for value in progressValues {
            XCTAssertGreaterThanOrEqual(value, 0.0, "Progress must not go below 0")
            XCTAssertLessThanOrEqual(value, 1.0, "Progress must not exceed 1")
        }
        for idx in 1..<progressValues.count {
            XCTAssertGreaterThanOrEqual(
                progressValues[idx],
                progressValues[idx - 1],
                "Progress should be monotonic non-decreasing"
            )
        }
    }

    func testProgressHandlerMonotonicBoundedForLargeVCF() throws {
        var lines = [
            "##fileformat=VCFv4.3",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2\tS3"
        ]
        for i in 1...25_000 {
            lines.append("chr1\t\(i)\trs\(i)\tA\tG\t30.0\tPASS\tDP=10\tGT\t0/1\t1/1\t0/0")
        }
        let bigVCF = lines.joined(separator: "\n")
        let vcfURL = try createTempVCF(content: bigVCF, name: "progress_large.vcf")
        let dbURL = tempDir.appendingPathComponent("progress_large.db")

        nonisolated(unsafe) var progressValues: [Double] = []
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            parseGenotypes: true,
            progressHandler: { fraction, _ in
                progressValues.append(fraction)
            }
        )

        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertEqual(try XCTUnwrap(progressValues.last), 1.0, accuracy: 0.0001)
        for value in progressValues {
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
        for idx in 1..<progressValues.count {
            XCTAssertGreaterThanOrEqual(progressValues[idx], progressValues[idx - 1])
        }
    }

    func testCancellationStopsPlainVCFImportWithoutDoneProgress() throws {
        var lines = [
            "##fileformat=VCFv4.3",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2"
        ]
        for i in 1...50_000 {
            lines.append("chr1\t\(i)\trs\(i)\tA\tG\t30.0\tPASS\tDP=10\tGT\t0/1\t0/0")
        }
        let vcfURL = try createTempVCF(content: lines.joined(separator: "\n"), name: "cancel_plain.vcf")
        let dbURL = tempDir.appendingPathComponent("cancel_plain.db")
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        nonisolated(unsafe) var progressValues: [Double] = []
        nonisolated(unsafe) var messages: [String] = []

        XCTAssertThrowsError(
            try VariantDatabase.createFromVCF(
                vcfURL: vcfURL,
                outputURL: dbURL,
                parseGenotypes: true,
                progressHandler: { fraction, message in
                    progressValues.append(fraction)
                    messages.append(message)
                    if fraction >= 0.20 {
                        cancelFlag.withLock { $0 = true }
                    }
                },
                shouldCancel: { cancelFlag.withLock { $0 } }
            )
        ) { error in
            guard case VariantDatabaseError.cancelled = error else {
                return XCTFail("Expected cancelled error, got \(error)")
            }
        }

        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertLessThan(try XCTUnwrap(progressValues.last), 1.0)
        XCTAssertFalse(messages.contains(where: { $0.contains("Done") }))
    }

    func testCancellationStopsGzipVCFImportWithoutDoneProgress() throws {
        var lines = [
            "##fileformat=VCFv4.3",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2"
        ]
        for i in 1...10_000 {
            lines.append("chr1\t\(i)\trs\(i)\tA\tG\t30.0\tPASS\tDP=10\tGT\t0/1\t0/0")
        }
        let plainURL = try createTempVCF(content: lines.joined(separator: "\n"), name: "cancel_gzip.vcf")
        let gzURL = tempDir.appendingPathComponent("cancel_gzip.vcf.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", plainURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let gzData = pipe.fileHandleForReading.readDataToEndOfFile()
        try gzData.write(to: gzURL)

        let dbURL = tempDir.appendingPathComponent("cancel_gzip.db")
        let cancelFlag = OSAllocatedUnfairLock(initialState: true)
        nonisolated(unsafe) var progressValues: [Double] = []
        nonisolated(unsafe) var messages: [String] = []

        XCTAssertThrowsError(
            try VariantDatabase.createFromVCF(
                vcfURL: gzURL,
                outputURL: dbURL,
                parseGenotypes: true,
                progressHandler: { fraction, message in
                    progressValues.append(fraction)
                    messages.append(message)
                },
                shouldCancel: { cancelFlag.withLock { $0 } }
            )
        ) { error in
            guard case VariantDatabaseError.cancelled = error else {
                return XCTFail("Expected cancelled error, got \(error)")
            }
        }

        if let last = progressValues.last {
            XCTAssertLessThan(last, 1.0)
        }
        XCTAssertFalse(messages.contains(where: { $0.contains("Done") }))
    }

    // MARK: - Sample Metadata

    func testSampleMetadataEmptyByDefault() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)
        let meta = db.sampleMetadata(name: "SAMPLE_A")
        XCTAssertTrue(meta.isEmpty, "Metadata should be empty after VCF import")
    }

    func testUpdateSampleMetadata() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        try db.updateSampleMetadata(
            name: "SAMPLE_A",
            metadata: ["sex": "male", "population": "EUR"]
        )

        let meta = db.sampleMetadata(name: "SAMPLE_A")
        XCTAssertEqual(meta["sex"], "male")
        XCTAssertEqual(meta["population"], "EUR")

        // Other samples should be unaffected
        let metaB = db.sampleMetadata(name: "SAMPLE_B")
        XCTAssertTrue(metaB.isEmpty)
    }

    func testUpdateSampleMetadataOverwrite() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        try db.updateSampleMetadata(name: "SAMPLE_A", metadata: ["sex": "male"])
        try db.updateSampleMetadata(name: "SAMPLE_A", metadata: ["sex": "female", "age": "30"])

        let meta = db.sampleMetadata(name: "SAMPLE_A")
        XCTAssertEqual(meta["sex"], "female", "Should overwrite existing value")
        XCTAssertEqual(meta["age"], "30", "Should add new field")
    }

    func testAllSampleMetadata() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        try db.updateSampleMetadata(name: "SAMPLE_A", metadata: ["sex": "male"])
        try db.updateSampleMetadata(name: "SAMPLE_B", metadata: ["sex": "female"])

        let all = db.allSampleMetadata()
        XCTAssertEqual(all.count, 3)

        let a = all.first { $0.name == "SAMPLE_A" }
        XCTAssertEqual(a?.metadata["sex"], "male")
    }

    func testMetadataFieldNames() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        try db.updateSampleMetadata(name: "SAMPLE_A", metadata: ["sex": "male", "population": "EUR"])
        try db.updateSampleMetadata(name: "SAMPLE_B", metadata: ["sex": "female", "cohort": "case"])

        let fields = db.metadataFieldNames()
        XCTAssertTrue(fields.contains("sex"))
        XCTAssertTrue(fields.contains("population"))
        XCTAssertTrue(fields.contains("cohort"))
    }

    func testUpdateMetadataReadOnlyThrows() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)  // Read-only (default)

        XCTAssertThrowsError(
            try db.updateSampleMetadata(name: "SAMPLE_A", metadata: ["sex": "male"])
        ) { error in
            XCTAssertTrue(error is VariantDatabaseError)
        }
    }

    // MARK: - TSV Metadata Import

    func testImportMetadataFromTSV() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        let tsvContent = "sample_name\tsex\tpopulation\tage\nSAMPLE_A\tmale\tEUR\t30\nSAMPLE_B\tfemale\tAFR\t25\nSAMPLE_C\tmale\tASN\t35"
        let tsvURL = tempDir.appendingPathComponent("metadata.tsv")
        try tsvContent.write(to: tsvURL, atomically: true, encoding: .utf8)

        let updatedCount = try db.importSampleMetadata(from: tsvURL, format: .tsv)
        XCTAssertEqual(updatedCount, 3)

        let metaA = db.sampleMetadata(name: "SAMPLE_A")
        XCTAssertEqual(metaA["sex"], "male")
        XCTAssertEqual(metaA["population"], "EUR")
        XCTAssertEqual(metaA["age"], "30")

        let metaB = db.sampleMetadata(name: "SAMPLE_B")
        XCTAssertEqual(metaB["sex"], "female")
        XCTAssertEqual(metaB["population"], "AFR")
    }

    func testImportMetadataSkipsUnknownSamples() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        let tsvContent = "sample_name\tsex\nSAMPLE_A\tmale\nUNKNOWN_SAMPLE\tfemale"
        let tsvURL = tempDir.appendingPathComponent("metadata.tsv")
        try tsvContent.write(to: tsvURL, atomically: true, encoding: .utf8)

        let updatedCount = try db.importSampleMetadata(from: tsvURL, format: .tsv)
        XCTAssertEqual(updatedCount, 1, "Only matching samples should be updated")

        let meta = db.sampleMetadata(name: "SAMPLE_A")
        XCTAssertEqual(meta["sex"], "male")
    }

    func testImportMetadataMergesWithExisting() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        // First, set some metadata directly
        try db.updateSampleMetadata(name: "SAMPLE_A", metadata: ["cohort": "control"])

        // Then import from TSV
        let tsvContent = "sample_name\tsex\nSAMPLE_A\tmale"
        let tsvURL = tempDir.appendingPathComponent("metadata.tsv")
        try tsvContent.write(to: tsvURL, atomically: true, encoding: .utf8)

        try db.importSampleMetadata(from: tsvURL, format: .tsv)

        let meta = db.sampleMetadata(name: "SAMPLE_A")
        XCTAssertEqual(meta["sex"], "male", "New field should be added")
        XCTAssertEqual(meta["cohort"], "control", "Existing field should be preserved")
    }

    // MARK: - CSV Metadata Import

    func testImportMetadataFromCSV() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        let csvContent = "sample_name,sex,population\nSAMPLE_A,male,EUR\nSAMPLE_B,female,AFR"
        let csvURL = tempDir.appendingPathComponent("metadata.csv")
        try csvContent.write(to: csvURL, atomically: true, encoding: .utf8)

        let updatedCount = try db.importSampleMetadata(from: csvURL, format: .csv)
        XCTAssertEqual(updatedCount, 2)

        let meta = db.sampleMetadata(name: "SAMPLE_A")
        XCTAssertEqual(meta["sex"], "male")
        XCTAssertEqual(meta["population"], "EUR")
    }

    func testCSVWithQuotedFields() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        let csvContent = "sample_name,description,sex\nSAMPLE_A,\"Description with, commas\",male\nSAMPLE_B,\"Simple description\",female"
        let csvURL = tempDir.appendingPathComponent("quoted.csv")
        try csvContent.write(to: csvURL, atomically: true, encoding: .utf8)

        try db.importSampleMetadata(from: csvURL, format: .csv)

        let meta = db.sampleMetadata(name: "SAMPLE_A")
        XCTAssertEqual(meta["description"], "Description with, commas")
        XCTAssertEqual(meta["sex"], "male")
    }

    func testImportMetadataFromEmptyFile() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        let emptyContent = "sample_name\tsex"  // Only header, no data rows
        let tsvURL = tempDir.appendingPathComponent("empty.tsv")
        try emptyContent.write(to: tsvURL, atomically: true, encoding: .utf8)

        let updatedCount = try db.importSampleMetadata(from: tsvURL, format: .tsv)
        XCTAssertEqual(updatedCount, 0)
    }

    func testImportMetadataFromSingleColumnFile() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)

        // Only sample name column, no metadata columns
        let tsvContent = "sample_name\nSAMPLE_A"
        let tsvURL = tempDir.appendingPathComponent("single_col.tsv")
        try tsvContent.write(to: tsvURL, atomically: true, encoding: .utf8)

        let updatedCount = try db.importSampleMetadata(from: tsvURL, format: .tsv)
        XCTAssertEqual(updatedCount, 0, "Need at least 2 columns (name + field)")
    }

    // MARK: - Compressed VCF

    func testCompressedVCFImport() throws {
        // Create a plain VCF, compress it with gzip, then import
        let vcfURL = try createTempVCF(content: singleSampleVCF, name: "test.vcf")
        let gzURL = tempDir.appendingPathComponent("test.vcf.gz")

        // Compress with gzip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", vcfURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let gzData = pipe.fileHandleForReading.readDataToEndOfFile()
        try gzData.write(to: gzURL)

        let dbURL = tempDir.appendingPathComponent("compressed.db")
        let count = try VariantDatabase.createFromVCF(vcfURL: gzURL, outputURL: dbURL)
        XCTAssertEqual(count, 3, "Should parse same 3 variants from compressed VCF")

        let db = try VariantDatabase(url: dbURL)
        XCTAssertEqual(db.sampleCount(), 1)
        XCTAssertEqual(db.sampleNames(), ["NAHQ01"])
    }

    func testCompressedVCFProgressIsBoundedAndMonotonic() throws {
        let vcfURL = try createTempVCF(content: singleSampleVCF, name: "progress_test.vcf")
        let gzURL = tempDir.appendingPathComponent("progress_test.vcf.gz")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", vcfURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let gzData = pipe.fileHandleForReading.readDataToEndOfFile()
        try gzData.write(to: gzURL)

        let dbURL = tempDir.appendingPathComponent("progress_compressed.db")
        nonisolated(unsafe) var progressValues: [Double] = []
        try VariantDatabase.createFromVCF(
            vcfURL: gzURL,
            outputURL: dbURL,
            parseGenotypes: true,
            progressHandler: { fraction, _ in
                progressValues.append(fraction)
            }
        )

        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertEqual(try XCTUnwrap(progressValues.last), 1.0, accuracy: 0.0001)
        for value in progressValues {
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
        for idx in 1..<progressValues.count {
            XCTAssertGreaterThanOrEqual(progressValues[idx], progressValues[idx - 1])
        }
    }

    func testEstimateGzipUncompressedSizeUsesFooterISIZE() throws {
        // Generate a VCF large enough that compressed < uncompressed (gzip needs
        // repetitive content before compression ratio drops below 1.0).
        var lines = [
            "##fileformat=VCFv4.3",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO"
        ]
        for i in 1...500 {
            lines.append("chr1\t\(i)\t.\tA\tG\t10\tPASS\tDP=10")
        }
        let content = lines.joined(separator: "\n")
        let plainURL = try createTempVCF(content: content, name: "estimate.vcf")
        let gzURL = tempDir.appendingPathComponent("estimate.vcf.gz")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", plainURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let gzData = pipe.fileHandleForReading.readDataToEndOfFile()
        try gzData.write(to: gzURL)

        let compressedSize = Int64(gzData.count)
        let uncompressedSize = Int64(content.utf8.count)
        // Verify our test data actually compresses (uncompressed > compressed)
        XCTAssertGreaterThan(uncompressedSize, compressedSize, "Test VCF must be large enough to compress")

        let estimate = VariantDatabase.estimateGzipUncompressedSize(url: gzURL, compressedSize: compressedSize)
        XCTAssertEqual(estimate, uncompressedSize, "Estimator should use gzip ISIZE footer when available")
    }

    func testEstimateGzipFallsBackWhenISIZESmallerThanCompressed() throws {
        // For tiny files where gzip overhead makes compressed > uncompressed,
        // ISIZE < compressedSize triggers heuristic fallback (compressedSize * 8).
        let content = "##fileformat=VCFv4.3\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t1\t.\tA\tG\t10\tPASS\t."
        let plainURL = try createTempVCF(content: content, name: "tiny_estimate.vcf")
        let gzURL = tempDir.appendingPathComponent("tiny_estimate.vcf.gz")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", plainURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let gzData = pipe.fileHandleForReading.readDataToEndOfFile()
        try gzData.write(to: gzURL)

        let compressedSize = Int64(gzData.count)
        let estimate = VariantDatabase.estimateGzipUncompressedSize(url: gzURL, compressedSize: compressedSize)
        // Should fall back to heuristic since ISIZE < compressedSize for tiny files
        XCTAssertEqual(estimate, compressedSize * 8, "Should use heuristic fallback for tiny/bgzip files")
    }

    // MARK: - Read/Write Mode

    func testReadWriteMode() throws {
        let vcfURL = try createTempVCF(content: multiSampleVCF)
        let dbURL = tempDir.appendingPathComponent("rw.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)

        let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
        XCTAssertEqual(rwDB.totalCount(), 4)
        XCTAssertEqual(rwDB.sampleCount(), 3)

        // Should be able to update metadata
        try rwDB.updateSampleMetadata(name: "SAMPLE_A", metadata: ["test": "value"])
        XCTAssertEqual(rwDB.sampleMetadata(name: "SAMPLE_A")["test"], "value")
    }

    func testDeleteVariantsDeletesOnlySpecifiedRowsAndReturnsActualCount() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)
        let chr1Variants = db.query(chromosome: "chr1", start: 0, end: 10_000)
        XCTAssertEqual(chr1Variants.count, 3)
        let idsToDelete = chr1Variants.prefix(2).compactMap(\.id)
        XCTAssertEqual(idsToDelete.count, 2)

        let deleted = try db.deleteVariants(ids: idsToDelete)
        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(db.totalCount(), 2)

        for id in idsToDelete {
            XCTAssertTrue(db.genotypes(forVariantId: id).isEmpty, "Genotypes for deleted variants should be removed")
        }
    }

    func testDeleteAllVariantsReturnsDeletedCount() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)
        XCTAssertEqual(db.totalCount(), 4)
        let deleted = try db.deleteAllVariants()
        XCTAssertEqual(deleted, 4)
        XCTAssertEqual(db.totalCount(), 0)
        XCTAssertTrue(db.genotypesInRegion(chromosome: "chr1", start: 0, end: 10_000).isEmpty)
    }

    func testDefaultReadOnlyMode() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)
        // Queries should work fine
        XCTAssertEqual(db.totalCount(), 4)
        XCTAssertEqual(db.sampleCount(), 3)

        // But writing should fail
        XCTAssertThrowsError(
            try db.updateSampleMetadata(name: "SAMPLE_A", metadata: ["test": "value"])
        )
    }

    // MARK: - classifyVariant (internal access)

    func testClassifyVariantSNP() {
        XCTAssertEqual(VariantDatabase.classifyVariant(ref: "A", alts: ["G"]), "SNP")
        XCTAssertEqual(VariantDatabase.classifyVariant(ref: "C", alts: ["T"]), "SNP")
    }

    func testClassifyVariantDeletion() {
        XCTAssertEqual(VariantDatabase.classifyVariant(ref: "ATCG", alts: ["A"]), "DEL")
    }

    func testClassifyVariantInsertion() {
        XCTAssertEqual(VariantDatabase.classifyVariant(ref: "A", alts: ["ATCG"]), "INS")
    }

    func testClassifyVariantMNP() {
        XCTAssertEqual(VariantDatabase.classifyVariant(ref: "AT", alts: ["GC"]), "MNP")
    }

    func testClassifyVariantLengthDifference() {
        // When ref and alt have different lengths and aren't pure SNP/MNP,
        // classifier uses length comparison: shorter ref = INS, longer ref = DEL
        XCTAssertEqual(VariantDatabase.classifyVariant(ref: "AT", alts: ["GCG"]), "INS")
    }

    func testClassifyVariantSymbolicAlt() {
        // Symbolic alts like <DEL> have length > 1, so classified by length comparison
        XCTAssertEqual(VariantDatabase.classifyVariant(ref: "N", alts: ["<DEL>"]), "INS")
    }

    // MARK: - Large Multi-Sample VCF

    func testLargeMultiSampleVCF() throws {
        var lines = [
            "##fileformat=VCFv4.3",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "##FORMAT=<ID=DP,Number=1,Type=Integer,Description=\"Read depth\">"
        ]

        // Build header with 10 samples
        var header = "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT"
        for i in 1...10 {
            header += "\tSAMPLE_\(i)"
        }
        lines.append(header)

        // 500 variants with 10 samples each
        let genotypes = ["0/0", "0/1", "1/1", "./."]
        for v in 1...500 {
            var line = "chr1\t\(v * 10)\trs\(v)\tA\tG\t30.0\tPASS\tDP=50\tGT:DP"
            for _ in 1...10 {
                let gt = genotypes[Int.random(in: 0..<genotypes.count)]
                let dp = Int.random(in: 10...50)
                line += "\t\(gt):\(dp)"
            }
            lines.append(line)
        }

        let content = lines.joined(separator: "\n")
        let vcfURL = try createTempVCF(content: content, name: "large_multi.vcf")
        let dbURL = tempDir.appendingPathComponent("large_multi.db")

        let count = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        XCTAssertEqual(count, 500)

        let db = try VariantDatabase(url: dbURL)
        XCTAssertEqual(db.sampleCount(), 10)
        XCTAssertEqual(db.totalCount(), 500)

        // Query a region and verify genotypes
        let results = db.genotypesInRegion(chromosome: "chr1", start: 0, end: 100)
        XCTAssertTrue(results.count > 0)
        for (variant, gts) in results {
            // Each variant can have up to 10 genotypes (some might be ./. and skipped)
            XCTAssertTrue(gts.count <= 10)
            XCTAssertNotNil(variant.id)
        }
    }

    // MARK: - FORMAT Field Handling

    func testFormatWithOnlyGT() throws {
        // VCF with only GT in FORMAT (no DP, GQ, AD)
        let vcf = """
        ##fileformat=VCFv4.3
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2
        chr1\t100\t.\tA\tG\t30.0\tPASS\t.\tGT\t0/1\t1/1
        """
        let (db, _) = try createDatabase(from: vcf)

        let variants = db.query(chromosome: "chr1", start: 0, end: 200)
        let variant = try XCTUnwrap(variants.first)
        let gts = db.genotypes(forVariantId: variant.id!)
        XCTAssertEqual(gts.count, 2)

        let s1 = gts.first { $0.sampleName == "S1" }
        XCTAssertEqual(s1?.genotype, "0/1")
        XCTAssertNil(s1?.depth, "No DP in FORMAT → should be nil")
        XCTAssertNil(s1?.genotypeQuality, "No GQ in FORMAT → should be nil")
        XCTAssertNil(s1?.alleleDepths, "No AD in FORMAT → should be nil")
    }

    func testFormatWithMissingValues() throws {
        // DP and GQ present in FORMAT but missing (.) in sample data
        let vcf = """
        ##fileformat=VCFv4.3
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">
        ##FORMAT=<ID=GQ,Number=1,Type=Integer,Description="Genotype quality">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1
        chr1\t100\t.\tA\tG\t30.0\tPASS\t.\tGT:DP:GQ\t0/1:.:30
        """
        let (db, _) = try createDatabase(from: vcf)

        let variants = db.query(chromosome: "chr1", start: 0, end: 200)
        let variant = try XCTUnwrap(variants.first)
        let gts = db.genotypes(forVariantId: variant.id!)
        let s1 = try XCTUnwrap(gts.first)

        XCTAssertEqual(s1.genotype, "0/1")
        XCTAssertNil(s1.depth, "Missing '.' DP should be nil")
        XCTAssertEqual(s1.genotypeQuality, 30)
    }

    // MARK: - GenotypeCall Display Names

    func testGenotypeCallDisplayNames() {
        XCTAssertEqual(GenotypeCall.homRef.displayName, "Hom Ref")
        XCTAssertEqual(GenotypeCall.het.displayName, "Het")
        XCTAssertEqual(GenotypeCall.homAlt.displayName, "Hom Alt")
        XCTAssertEqual(GenotypeCall.noCall.displayName, "No Call")
    }

    func testGenotypeCallCaseIterable() {
        XCTAssertEqual(GenotypeCall.allCases.count, 4)
    }

    // MARK: - MetadataFormat

    func testMetadataFormatRawValues() {
        XCTAssertEqual(MetadataFormat.tsv.rawValue, "tsv")
        XCTAssertEqual(MetadataFormat.csv.rawValue, "csv")
        XCTAssertEqual(MetadataFormat.excel.rawValue, "excel")
    }

    func testExcelFormatThrows() throws {
        let (db, _) = try createWritableDatabase(from: multiSampleVCF)
        let fakeExcel = tempDir.appendingPathComponent("fake.xlsx")
        try "fake".write(to: fakeExcel, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try db.importSampleMetadata(from: fakeExcel, format: .excel)
        )
    }

    // MARK: - V3 Import Optimizations

    func testSampleCountPreservedWithOmitHomref() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        // rs100: all 3 samples called (including 0/0) — sample_count should still be 3
        let v1 = db.query(chromosome: "chr1", start: 99, end: 100)
        XCTAssertEqual(v1.first?.sampleCount, 3, "sample_count should count all called samples, including hom-ref")

        // rs200: 2 called (SAMPLE_A=0/0, SAMPLE_B=0/1), SAMPLE_C=./. — sample_count should be 2
        let v2 = db.query(chromosome: "chr1", start: 199, end: 200)
        XCTAssertEqual(v2.first?.sampleCount, 2)
    }

    func testVariantInfoStoredButRawInfoNull() throws {
        let (db, _) = try createDatabase(from: multiSampleVCF)

        // v3: raw info string is not stored in the variants table
        let variants = db.query(chromosome: "chr1", start: 99, end: 100)
        let variant = try XCTUnwrap(variants.first)
        XCTAssertNil(variant.info, "v3 databases should not store raw INFO string")

        // But structured INFO values should be available via variant_info EAV table
        let infoValues = db.infoValues(variantId: variant.id!)
        XCTAssertEqual(infoValues["DP"], "100", "Structured INFO values should be available")
    }
}
