// AnnotationConverterTests.swift - Tests for annotation converter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class AnnotationConverterTests: XCTestCase {

    // MARK: - Test Fixtures

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationConverterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Input Format Detection Tests

    func testDetectGFF3Format() {
        let url1 = URL(fileURLWithPath: "/test/file.gff3")
        let url2 = URL(fileURLWithPath: "/test/file.gff")

        XCTAssertEqual(AnnotationConverter.InputFormat.detect(from: url1), .gff3)
        XCTAssertEqual(AnnotationConverter.InputFormat.detect(from: url2), .gff3)
    }

    func testDetectGTFFormat() {
        let url = URL(fileURLWithPath: "/test/file.gtf")
        XCTAssertEqual(AnnotationConverter.InputFormat.detect(from: url), .gtf)
    }

    func testDetectBEDFormat() {
        let url = URL(fileURLWithPath: "/test/file.bed")
        XCTAssertEqual(AnnotationConverter.InputFormat.detect(from: url), .bed)
    }

    func testDetectGenBankFormat() {
        let url1 = URL(fileURLWithPath: "/test/file.gb")
        let url2 = URL(fileURLWithPath: "/test/file.gbk")
        let url3 = URL(fileURLWithPath: "/test/file.genbank")

        XCTAssertEqual(AnnotationConverter.InputFormat.detect(from: url1), .genbank)
        XCTAssertEqual(AnnotationConverter.InputFormat.detect(from: url2), .genbank)
        XCTAssertEqual(AnnotationConverter.InputFormat.detect(from: url3), .genbank)
    }

    func testDetectUnknownFormat() {
        let url = URL(fileURLWithPath: "/test/file.txt")
        XCTAssertNil(AnnotationConverter.InputFormat.detect(from: url))
    }

    // MARK: - BED Format Tests

    func testBEDFormatColumns() {
        XCTAssertEqual(AnnotationConverter.BEDFormat.bed6.columns, 6)
        XCTAssertEqual(AnnotationConverter.BEDFormat.bed12.columns, 12)
    }

    // MARK: - Conversion Options Tests

    func testDefaultConversionOptions() {
        let options = AnnotationConverter.ConversionOptions.default

        XCTAssertEqual(options.bedFormat.columns, 6) // bed6 is default
        XCTAssertNil(options.featureTypes)
        XCTAssertFalse(options.mergeOverlapping)
        XCTAssertNil(options.minLength)
        XCTAssertNil(options.maxLength)
    }

    func testCustomConversionOptions() {
        let options = AnnotationConverter.ConversionOptions(
            bedFormat: .bed12,
            featureTypes: ["gene", "exon"],
            mergeOverlapping: true,
            minLength: 100,
            maxLength: 10000
        )

        XCTAssertEqual(options.bedFormat.columns, 12)
        XCTAssertEqual(options.featureTypes, ["gene", "exon"])
        XCTAssertTrue(options.mergeOverlapping)
        XCTAssertEqual(options.minLength, 100)
        XCTAssertEqual(options.maxLength, 10000)
    }

    // MARK: - GFF3 Conversion Tests

    func testConvertGFF3ToBED() async throws {
        // Create test GFF3 file
        let gff3Content = """
        ##gff-version 3
        chr1\tLungfish\tgene\t1000\t2000\t.\t+\t.\tID=gene1;Name=TestGene
        chr1\tLungfish\texon\t1000\t1500\t.\t+\t.\tID=exon1;Parent=gene1
        chr2\tLungfish\tgene\t500\t1500\t.\t-\t.\tID=gene2;Name=OtherGene
        """
        let gff3URL = tempDirectory.appendingPathComponent("test.gff3")
        try gff3Content.write(to: gff3URL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bed")
        let converter = AnnotationConverter()

        let result = try await converter.convertToBED(
            from: gff3URL,
            format: .gff3,
            output: outputURL
        )

        XCTAssertEqual(result, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // Verify BED content
        let bedContent = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = bedContent.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)

        // Check first line (should be sorted by chromosome, position)
        // Gene and exon both start at 999, gene comes first (stable sort)
        let firstLine = lines[0].split(separator: "\t")
        XCTAssertEqual(firstLine[0], "chr1") // chrom
        XCTAssertEqual(firstLine[1], "999")  // start (0-based)
        XCTAssertEqual(firstLine[2], "2000") // end (gene ends at 2000)
    }

    func testConvertGFF3WithFeatureFilter() async throws {
        let gff3Content = """
        ##gff-version 3
        chr1\tLungfish\tgene\t1000\t2000\t.\t+\t.\tID=gene1;Name=TestGene
        chr1\tLungfish\texon\t1000\t1500\t.\t+\t.\tID=exon1;Parent=gene1
        chr1\tLungfish\tCDS\t1100\t1400\t.\t+\t.\tID=cds1;Parent=gene1
        """
        let gff3URL = tempDirectory.appendingPathComponent("test.gff3")
        try gff3Content.write(to: gff3URL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bed")
        let converter = AnnotationConverter()

        let options = AnnotationConverter.ConversionOptions(
            featureTypes: ["gene"]
        )

        _ = try await converter.convertToBED(
            from: gff3URL,
            format: .gff3,
            output: outputURL,
            options: options
        )

        let bedContent = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = bedContent.split(separator: "\n")
        XCTAssertEqual(lines.count, 1) // Only gene features
    }

    // MARK: - BED Conversion Tests

    func testConvertBEDToBED() async throws {
        let bedContent = """
        chr1\t100\t200\tfeature1\t500\t+
        chr1\t300\t400\tfeature2\t600\t-
        chr2\t50\t150\tfeature3\t700\t.
        """
        let bedURL = tempDirectory.appendingPathComponent("test.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bed")
        let converter = AnnotationConverter()

        let result = try await converter.convertToBED(
            from: bedURL,
            format: .bed,
            output: outputURL
        )

        XCTAssertEqual(result, outputURL)

        let outputContent = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = outputContent.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
    }

    func testConvertBEDWithLengthFilter() async throws {
        let bedContent = """
        chr1\t100\t150\tshort\t0\t+
        chr1\t200\t400\tmedium\t0\t+
        chr1\t500\t2000\tlong\t0\t+
        """
        let bedURL = tempDirectory.appendingPathComponent("test.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bed")
        let converter = AnnotationConverter()

        let options = AnnotationConverter.ConversionOptions(
            minLength: 100,
            maxLength: 500
        )

        _ = try await converter.convertToBED(
            from: bedURL,
            format: .bed,
            output: outputURL,
            options: options
        )

        let outputContent = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = outputContent.split(separator: "\n")
        XCTAssertEqual(lines.count, 1) // Only medium feature passes filter
    }

    // MARK: - Progress Callback Tests

    func testProgressCallback() async throws {
        let gff3Content = """
        ##gff-version 3
        chr1\tLungfish\tgene\t1000\t2000\t.\t+\t.\tID=gene1
        """
        let gff3URL = tempDirectory.appendingPathComponent("test.gff3")
        try gff3Content.write(to: gff3URL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bed")
        let converter = AnnotationConverter()

        // Use nonisolated(unsafe) to allow mutation from the progress callback
        // This is safe because the callback is called sequentially during conversion
        nonisolated(unsafe) var progressValues: [(Double, String)] = []

        _ = try await converter.convertToBED(
            from: gff3URL,
            format: .gff3,
            output: outputURL,
            progress: { progress, message in
                progressValues.append((progress, message))
            }
        )

        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertEqual(progressValues.last?.0, 1.0)
    }

    // MARK: - Error Tests

    func testUnsupportedFormatError() async {
        let txtURL = tempDirectory.appendingPathComponent("test.txt")
        try? "test".write(to: txtURL, atomically: true, encoding: .utf8)

        let outputURL = tempDirectory.appendingPathComponent("output.bed")
        let converter = AnnotationConverter()

        do {
            _ = try await converter.convertToBED(
                from: txtURL,
                output: outputURL
            )
            XCTFail("Expected unsupportedFormat error")
        } catch let error as AnnotationConversionError {
            if case .unsupportedFormat(let ext) = error {
                XCTAssertEqual(ext, "txt")
            } else {
                XCTFail("Expected unsupportedFormat error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Error Description Tests

    func testAnnotationConversionErrorDescriptions() {
        let unsupportedError = AnnotationConversionError.unsupportedFormat("xyz")
        XCTAssertTrue(unsupportedError.localizedDescription.contains("xyz"))

        let readError = AnnotationConversionError.readFailed("file not found")
        XCTAssertTrue(readError.localizedDescription.contains("file not found"))

        let writeError = AnnotationConversionError.writeFailed("permission denied")
        XCTAssertTrue(writeError.localizedDescription.contains("permission denied"))

        let noFeaturesError = AnnotationConversionError.noFeatures
        XCTAssertTrue(noFeaturesError.localizedDescription.contains("No features"))
    }

    func testAnnotationConversionErrorRecoverySuggestions() {
        let unsupportedError = AnnotationConversionError.unsupportedFormat("xyz")
        XCTAssertNotNil(unsupportedError.recoverySuggestion)
        XCTAssertTrue(unsupportedError.recoverySuggestion!.contains("GFF3"))

        let readError = AnnotationConversionError.readFailed("test")
        XCTAssertNotNil(readError.recoverySuggestion)

        let noFeaturesError = AnnotationConversionError.noFeatures
        XCTAssertNotNil(noFeaturesError.recoverySuggestion)
    }
}
