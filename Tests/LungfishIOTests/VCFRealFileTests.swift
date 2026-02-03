// VCFRealFileTests.swift - Tests for VCF reader with real files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

/// Tests VCF parsing with the actual test_variants.vcf file from the test project.
/// These tests verify real-world VCF parsing capabilities.
final class VCFRealFileTests: XCTestCase {

    // MARK: - Test with Real VCF File

    /// Tests parsing the comprehensive test_variants.vcf file from the test project.
    /// This file contains:
    /// - VCF v4.2 format
    /// - 4 contigs (TestSequence1, Chromosome1, Chromosome2, LargeChromosome1)
    /// - 3 samples (Sample1, Sample2, Sample3)
    /// - 22 variants including SNPs, insertions, and deletions
    /// - Various filter statuses (PASS, q10, LowCov)
    /// - Rich INFO and FORMAT fields
    func testParseTestVariantsFile() async throws {
        // Path to the actual test file
        let testFilePath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_variants.vcf"
        let url = URL(fileURLWithPath: testFilePath)

        // Skip test if file doesn't exist (for CI environments)
        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test VCF file not found at expected location")
        }

        let reader = VCFReader()

        // Test header parsing
        let header = try await reader.readHeader(from: url)

        // Verify file format
        XCTAssertEqual(header.fileFormat, "VCFv4.2", "File format should be VCFv4.2")

        // Verify contig definitions
        XCTAssertEqual(header.contigs.count, 4, "Should have 4 contigs defined")
        XCTAssertEqual(header.contigs["TestSequence1"], 1000)
        XCTAssertEqual(header.contigs["Chromosome1"], 500)
        XCTAssertEqual(header.contigs["Chromosome2"], 400)
        XCTAssertEqual(header.contigs["LargeChromosome1"], 10000)

        // Verify INFO field definitions
        XCTAssertEqual(header.infoFields.count, 7, "Should have 7 INFO fields")
        XCTAssertNotNil(header.infoFields["DP"])
        XCTAssertNotNil(header.infoFields["AF"])
        XCTAssertNotNil(header.infoFields["NS"])
        XCTAssertNotNil(header.infoFields["DB"])
        XCTAssertNotNil(header.infoFields["TYPE"])
        XCTAssertNotNil(header.infoFields["GENE"])
        XCTAssertNotNil(header.infoFields["EFFECT"])

        // Verify FORMAT field definitions
        XCTAssertEqual(header.formatFields.count, 5, "Should have 5 FORMAT fields")
        XCTAssertNotNil(header.formatFields["GT"])
        XCTAssertNotNil(header.formatFields["GQ"])
        XCTAssertNotNil(header.formatFields["DP"])
        XCTAssertNotNil(header.formatFields["AD"])
        XCTAssertNotNil(header.formatFields["PL"])

        // Verify FILTER definitions
        XCTAssertEqual(header.filters.count, 3, "Should have 3 filters defined")
        XCTAssertNotNil(header.filters["q10"])
        XCTAssertNotNil(header.filters["s50"])
        XCTAssertNotNil(header.filters["LowCov"])

        // Verify sample names
        XCTAssertEqual(header.sampleNames, ["Sample1", "Sample2", "Sample3"])

        // Parse all variants
        let variants = try await reader.readAll(from: url)
        XCTAssertEqual(variants.count, 22, "Should have 22 variant records")

        // Verify variant types
        let snps = variants.filter { $0.isSNP }
        let indels = variants.filter { $0.isIndel }
        XCTAssertGreaterThan(snps.count, 0, "Should have SNPs")
        XCTAssertGreaterThan(indels.count, 0, "Should have indels")

        // Verify filter statuses
        let passingVariants = variants.filter { $0.isPassing }
        let filteredVariants = variants.filter { !$0.isPassing }
        XCTAssertGreaterThan(passingVariants.count, 0, "Should have passing variants")
        XCTAssertGreaterThan(filteredVariants.count, 0, "Should have filtered variants")

        // Verify chromosomes represented
        let chromosomes = Set(variants.map { $0.chromosome })
        XCTAssertTrue(chromosomes.contains("TestSequence1"))
        XCTAssertTrue(chromosomes.contains("Chromosome1"))
        XCTAssertTrue(chromosomes.contains("Chromosome2"))
        XCTAssertTrue(chromosomes.contains("LargeChromosome1"))

        // Test first variant in detail
        let firstVariant = variants[0]
        XCTAssertEqual(firstVariant.id, "rs001")
        XCTAssertEqual(firstVariant.chromosome, "TestSequence1")
        XCTAssertEqual(firstVariant.position, 50)
        XCTAssertEqual(firstVariant.ref, "A")
        XCTAssertEqual(firstVariant.alt, ["G"])
        XCTAssertEqual(firstVariant.quality, 99)
        XCTAssertTrue(firstVariant.isPassing)
        XCTAssertTrue(firstVariant.isSNP)

        // Test genotypes
        XCTAssertEqual(firstVariant.genotypes.count, 3)
        let sample1GT = firstVariant.genotypes["Sample1"]
        XCTAssertNotNil(sample1GT)
        XCTAssertTrue(sample1GT!.isHet)
        XCTAssertEqual(sample1GT!.depth, 52)

        // Test INFO fields
        XCTAssertEqual(firstVariant.info["DP"], "150")
        XCTAssertEqual(firstVariant.info["GENE"], "testGeneA")
        XCTAssertEqual(firstVariant.info["EFFECT"], "synonymous")

        // Verify conversion to annotations
        let annotations = try await reader.readAsAnnotations(from: url)
        XCTAssertEqual(annotations.count, 22, "Should convert all 22 variants to annotations")

        // Verify annotation types
        let snpAnnotations = annotations.filter { $0.type == .snp }
        let variationAnnotations = annotations.filter { $0.type == .variation }
        XCTAssertGreaterThan(snpAnnotations.count, 0)
        XCTAssertGreaterThan(variationAnnotations.count, 0)

        // Verify coordinate conversion (VCF is 1-based, annotations are 0-based)
        let firstAnnotation = annotations[0]
        XCTAssertEqual(firstAnnotation.start, 49, "Position 50 should convert to 0-based index 49")
        XCTAssertEqual(firstAnnotation.name, "rs001")
    }

    /// Tests streaming variants from the real file.
    func testStreamVariantsFromRealFile() async throws {
        let testFilePath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_variants.vcf"
        let url = URL(fileURLWithPath: testFilePath)

        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test VCF file not found at expected location")
        }

        let reader = VCFReader()
        var count = 0
        var chromosomeCounts: [String: Int] = [:]

        for try await variant in reader.variants(from: url) {
            count += 1
            chromosomeCounts[variant.chromosome, default: 0] += 1
        }

        XCTAssertEqual(count, 22, "Should stream all 22 variants")
        XCTAssertEqual(chromosomeCounts["TestSequence1"], 8)
        XCTAssertEqual(chromosomeCounts["Chromosome1"], 3)
        XCTAssertEqual(chromosomeCounts["Chromosome2"], 3)
        XCTAssertEqual(chromosomeCounts["LargeChromosome1"], 8)
    }

    /// Tests variant classification (SNP vs indel).
    func testVariantClassification() async throws {
        let testFilePath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_variants.vcf"
        let url = URL(fileURLWithPath: testFilePath)

        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test VCF file not found at expected location")
        }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        // Find specific variants by ID and verify classification
        let deletion = variants.first { $0.id == "rs004" }
        XCTAssertNotNil(deletion)
        XCTAssertTrue(deletion!.isIndel, "rs004 (AT->A) should be classified as indel")
        XCTAssertEqual(deletion!.info["TYPE"], "DEL")

        let insertion = variants.first { $0.id == "rs005" }
        XCTAssertNotNil(insertion)
        XCTAssertTrue(insertion!.isIndel, "rs005 (G->GT) should be classified as indel")
        XCTAssertEqual(insertion!.info["TYPE"], "INS")

        let snp = variants.first { $0.id == "rs001" }
        XCTAssertNotNil(snp)
        XCTAssertTrue(snp!.isSNP, "rs001 (A->G) should be classified as SNP")
        XCTAssertEqual(snp!.info["TYPE"], "SNP")
    }

    /// Tests filter status parsing.
    func testFilterStatusParsing() async throws {
        let testFilePath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_variants.vcf"
        let url = URL(fileURLWithPath: testFilePath)

        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test VCF file not found at expected location")
        }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        // Check q10 filter (rs007)
        let q10Variant = variants.first { $0.id == "rs007" }
        XCTAssertNotNil(q10Variant)
        XCTAssertEqual(q10Variant!.filter, "q10")
        XCTAssertFalse(q10Variant!.isPassing)

        // Check LowCov filter (rs008)
        let lowCovVariant = variants.first { $0.id == "rs008" }
        XCTAssertNotNil(lowCovVariant)
        XCTAssertEqual(lowCovVariant!.filter, "LowCov")
        XCTAssertFalse(lowCovVariant!.isPassing)

        // Check PASS variants
        let passVariant = variants.first { $0.id == "rs001" }
        XCTAssertNotNil(passVariant)
        XCTAssertEqual(passVariant!.filter, "PASS")
        XCTAssertTrue(passVariant!.isPassing)
    }

    /// Tests genotype parsing including missing data.
    func testGenotypeParsing() async throws {
        let testFilePath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_variants.vcf"
        let url = URL(fileURLWithPath: testFilePath)

        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test VCF file not found at expected location")
        }

        let reader = VCFReader()
        let variants = try await reader.readAll(from: url)

        // rs008 has a missing genotype for Sample2 (./.)
        let variantWithMissing = variants.first { $0.id == "rs008" }
        XCTAssertNotNil(variantWithMissing)

        let missingSample = variantWithMissing!.genotypes["Sample2"]
        XCTAssertNotNil(missingSample)
        XCTAssertEqual(missingSample!.rawGenotype, "./.")

        // Test heterozygous genotype
        let hetVariant = variants.first { $0.id == "rs001" }
        let hetGT = hetVariant?.genotypes["Sample1"]
        XCTAssertNotNil(hetGT)
        XCTAssertTrue(hetGT!.isHet)
        XCTAssertEqual(hetGT!.alleleIndices, [0, 1])

        // Test homozygous reference genotype
        let homRefGT = hetVariant?.genotypes["Sample2"]
        XCTAssertNotNil(homRefGT)
        XCTAssertTrue(homRefGT!.isHomRef)
        XCTAssertEqual(homRefGT!.alleleIndices, [0, 0])
    }
}
