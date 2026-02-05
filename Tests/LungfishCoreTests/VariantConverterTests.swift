// VariantConverterTests.swift - Tests for variant converter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class VariantConverterTests: XCTestCase {

    // MARK: - Test Fixtures

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantConverterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Input Format Detection Tests

    func testDetectVCFFormat() {
        let url = URL(fileURLWithPath: "/test/file.vcf")
        XCTAssertEqual(VariantConverter.InputFormat.detect(from: url), .vcf)
    }

    func testDetectVCFGzFormat() {
        let url = URL(fileURLWithPath: "/test/file.vcf.gz")
        XCTAssertEqual(VariantConverter.InputFormat.detect(from: url), .vcfGz)
    }

    func testDetectBCFFormat() {
        let url = URL(fileURLWithPath: "/test/file.bcf")
        XCTAssertEqual(VariantConverter.InputFormat.detect(from: url), .bcf)
    }

    func testDetectUnknownFormat() {
        let url = URL(fileURLWithPath: "/test/file.txt")
        XCTAssertNil(VariantConverter.InputFormat.detect(from: url))
    }

    // MARK: - Conversion Options Tests

    func testDefaultConversionOptions() {
        let options = VariantConverter.ConversionOptions.default

        XCTAssertFalse(options.normalize)
        XCTAssertFalse(options.filterLowQuality)
        XCTAssertNil(options.minQuality)
        XCTAssertNil(options.regions)
        XCTAssertNil(options.samples)
    }

    func testCustomConversionOptions() {
        let options = VariantConverter.ConversionOptions(
            normalize: true,
            filterLowQuality: true,
            minQuality: 30.0,
            regions: ["chr1", "chr2"],
            samples: ["sample1", "sample2"]
        )

        XCTAssertTrue(options.normalize)
        XCTAssertTrue(options.filterLowQuality)
        XCTAssertEqual(options.minQuality, 30.0)
        XCTAssertEqual(options.regions, ["chr1", "chr2"])
        XCTAssertEqual(options.samples, ["sample1", "sample2"])
    }

    // MARK: - VCF Analysis Tests

    func testAnalyzeVCF() async throws {
        let vcfContent = """
        ##fileformat=VCFv4.2
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSample1\tSample2
        chr1\t100\t.\tA\tG\t30\tPASS\tDP=50\tGT\t0/1\t1/1
        chr1\t200\t.\tC\tT\t40\tPASS\tDP=60\tGT\t0/0\t0/1
        chr1\t300\t.\tG\tA,C\t50\tPASS\tDP=70\tGT\t1/2\t0/1
        chr2\t100\t.\tAT\tA\t35\tPASS\tDP=45\tGT\t0/1\t0/0
        chr2\t200\t.\tG\tGTT\t45\tPASS\tDP=55\tGT\t1/1\t0/1
        """
        let vcfURL = tempDirectory.appendingPathComponent("test.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let converter = VariantConverter()
        let stats = try await converter.analyzeVCF(from: vcfURL)

        XCTAssertEqual(stats.variantCount, 5)
        XCTAssertEqual(stats.snpCount, 4) // A>G, C>T, G>A, G>C
        XCTAssertEqual(stats.insertionCount, 1) // G>GTT
        XCTAssertEqual(stats.deletionCount, 1) // AT>A
        XCTAssertEqual(stats.multiAllelicCount, 1) // G>A,C
        XCTAssertEqual(stats.chromosomes, ["chr1", "chr2"])
        XCTAssertEqual(stats.samples, ["Sample1", "Sample2"])
    }

    func testAnalyzeEmptyVCF() async throws {
        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """
        let vcfURL = tempDirectory.appendingPathComponent("empty.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let converter = VariantConverter()
        let stats = try await converter.analyzeVCF(from: vcfURL)

        XCTAssertEqual(stats.variantCount, 0)
        XCTAssertEqual(stats.snpCount, 0)
        XCTAssertTrue(stats.chromosomes.isEmpty)
    }

    // MARK: - VCF Validation Tests

    func testValidateValidVCF() async throws {
        let vcfContent = """
        ##fileformat=VCFv4.2
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\tDP=50
        chr1\t200\t.\tC\tT\t40\tPASS\tDP=60
        """
        let vcfURL = tempDirectory.appendingPathComponent("valid.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let converter = VariantConverter()
        let issues = try await converter.validateVCF(from: vcfURL)

        XCTAssertTrue(issues.isEmpty)
    }

    func testValidateVCFMissingHeader() async throws {
        let vcfContent = """
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        """
        let vcfURL = tempDirectory.appendingPathComponent("noheader.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let converter = VariantConverter()
        let issues = try await converter.validateVCF(from: vcfURL)

        XCTAssertTrue(issues.contains { issue in
            if case .missingFileFormatHeader = issue { return true }
            return false
        })
    }

    func testValidateVCFUnsorted() async throws {
        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t200\t.\tA\tG\t30\tPASS\t.
        chr1\t100\t.\tC\tT\t40\tPASS\t.
        """
        let vcfURL = tempDirectory.appendingPathComponent("unsorted.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let converter = VariantConverter()
        let issues = try await converter.validateVCF(from: vcfURL)

        XCTAssertTrue(issues.contains { issue in
            if case .unsortedVariants = issue { return true }
            return false
        })
    }

    // MARK: - BCF Conversion Tests

    func testConvertVCFToBCF() async throws {
        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        chr1\t200\t.\tC\tT\t40\tPASS\t.
        """
        let vcfURL = tempDirectory.appendingPathComponent("test.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bcf")
        let converter = VariantConverter()

        let result = try await converter.convertToBCF(
            from: vcfURL,
            output: outputURL
        )

        XCTAssertEqual(result, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // Check index was created
        let indexURL = outputURL.appendingPathExtension("csi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
    }

    func testConvertVCFToBCFWithProgress() async throws {
        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        """
        let vcfURL = tempDirectory.appendingPathComponent("test.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bcf")
        let converter = VariantConverter()

        var progressValues: [(Double, String)] = []

        _ = try await converter.convertToBCF(
            from: vcfURL,
            output: outputURL,
            progress: { progress, message in
                progressValues.append((progress, message))
            }
        )

        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertEqual(progressValues.last?.0, 1.0)
    }

    // MARK: - Error Tests

    func testConvertNonexistentFile() async {
        let nonexistentURL = tempDirectory.appendingPathComponent("nonexistent.vcf")
        let outputURL = tempDirectory.appendingPathComponent("output.bcf")
        let converter = VariantConverter()

        do {
            _ = try await converter.convertToBCF(
                from: nonexistentURL,
                output: outputURL
            )
            XCTFail("Expected fileNotFound error")
        } catch let error as VariantConversionError {
            if case .fileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected fileNotFound error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConvertUnsupportedFormat() async {
        let txtURL = tempDirectory.appendingPathComponent("test.txt")
        try? "test".write(to: txtURL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bcf")
        let converter = VariantConverter()

        do {
            _ = try await converter.convertToBCF(
                from: txtURL,
                output: outputURL
            )
            XCTFail("Expected unsupportedFormat error")
        } catch let error as VariantConversionError {
            if case .unsupportedFormat(let ext) = error {
                XCTAssertEqual(ext, "txt")
            } else {
                XCTFail("Expected unsupportedFormat error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - VCF Validation Issue Tests

    func testVCFValidationIssueDescriptions() {
        let missingHeader = VCFValidationIssue.missingFileFormatHeader
        XCTAssertTrue(missingHeader.description.contains("fileformat"))

        let missingChrom = VCFValidationIssue.missingChromHeader
        XCTAssertTrue(missingChrom.description.contains("CHROM"))

        let invalidHeader = VCFValidationIssue.invalidHeaderLine(5)
        XCTAssertTrue(invalidHeader.description.contains("5"))

        let invalidData = VCFValidationIssue.invalidDataLine(10, "test reason")
        XCTAssertTrue(invalidData.description.contains("10"))
        XCTAssertTrue(invalidData.description.contains("test reason"))

        let unsorted = VCFValidationIssue.unsortedVariants(15)
        XCTAssertTrue(unsorted.description.contains("15"))

        let duplicate = VCFValidationIssue.duplicateVariant(20)
        XCTAssertTrue(duplicate.description.contains("20"))
    }

    // MARK: - Error Description Tests

    func testVariantConversionErrorDescriptions() {
        let unsupportedError = VariantConversionError.unsupportedFormat("xyz")
        XCTAssertTrue(unsupportedError.localizedDescription.contains("xyz"))

        let notFoundError = VariantConversionError.fileNotFound("/path/to/file")
        XCTAssertTrue(notFoundError.localizedDescription.contains("/path/to/file"))

        let invalidError = VariantConversionError.invalidVCF("test reason")
        XCTAssertTrue(invalidError.localizedDescription.contains("test reason"))

        let noVariantsError = VariantConversionError.noVariants
        XCTAssertTrue(noVariantsError.localizedDescription.contains("No variants"))
    }

    func testVariantConversionErrorRecoverySuggestions() {
        let unsupportedError = VariantConversionError.unsupportedFormat("xyz")
        XCTAssertNotNil(unsupportedError.recoverySuggestion)
        XCTAssertTrue(unsupportedError.recoverySuggestion!.contains("VCF"))

        let notFoundError = VariantConversionError.fileNotFound("/path")
        XCTAssertNotNil(notFoundError.recoverySuggestion)

        let invalidError = VariantConversionError.invalidVCF("test")
        XCTAssertNotNil(invalidError.recoverySuggestion)

        let noVariantsError = VariantConversionError.noVariants
        XCTAssertNotNil(noVariantsError.recoverySuggestion)
    }
}
