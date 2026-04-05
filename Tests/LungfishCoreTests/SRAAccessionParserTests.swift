// SRAAccessionParserTests.swift - Tests for SRA accession pattern detection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SRAAccessionParserTests: XCTestCase {

    // MARK: - Single Accession Detection

    func testDetectsSingleRunAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("SRR35517702"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("ERR1234567"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("DRR028938"))
    }

    func testDetectsExperimentAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("SRX123456"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("ERX789012"))
    }

    func testDetectsSampleAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("SRS123456"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("ERS789012"))
    }

    func testDetectsStudyAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("SRP123456"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("ERP789012"))
    }

    func testDetectsBioProjectAccession() {
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("PRJNA989177"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("PRJEB12345"))
        XCTAssertTrue(SRAAccessionParser.isSRAAccession("PRJDB67890"))
    }

    func testRejectsNonAccessionText() {
        XCTAssertFalse(SRAAccessionParser.isSRAAccession("SARS-CoV-2"))
        XCTAssertFalse(SRAAccessionParser.isSRAAccession("influenza"))
        XCTAssertFalse(SRAAccessionParser.isSRAAccession("air monitoring"))
        XCTAssertFalse(SRAAccessionParser.isSRAAccession("NC_045512"))
        XCTAssertFalse(SRAAccessionParser.isSRAAccession(""))
    }

    func testDetectsRunAccessionType() {
        XCTAssertEqual(SRAAccessionParser.accessionType("SRR35517702"), .run)
        XCTAssertEqual(SRAAccessionParser.accessionType("ERR1234567"), .run)
        XCTAssertEqual(SRAAccessionParser.accessionType("DRR028938"), .run)
    }

    func testDetectsStudyAccessionType() {
        XCTAssertEqual(SRAAccessionParser.accessionType("SRP123456"), .study)
        XCTAssertEqual(SRAAccessionParser.accessionType("PRJNA989177"), .bioProject)
    }

    func testNonAccessionReturnsNilType() {
        XCTAssertNil(SRAAccessionParser.accessionType("influenza"))
    }

    // MARK: - Multi-Accession Parsing

    func testParseNewlineSeparatedAccessions() {
        let input = "SRR35517702\nSRR35517703\nSRR35517705"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705"])
    }

    func testParseCommaSeparatedAccessions() {
        let input = "SRR35517702, SRR35517703, SRR35517705"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705"])
    }

    func testParseTabSeparatedAccessions() {
        let input = "SRR35517702\tSRR35517703\tSRR35517705"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705"])
    }

    func testParseMixedSeparators() {
        let input = "SRR35517702\nSRR35517703, SRR35517705\tSRR35517706"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705", "SRR35517706"])
    }

    func testParseIgnoresNonAccessionLines() {
        let input = "acc\nSRR35517702\nsome junk\nSRR35517703\n"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testParseDeduplicates() {
        let input = "SRR35517702\nSRR35517702\nSRR35517703"
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testParseEmptyString() {
        let result = SRAAccessionParser.parseAccessionList("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseTrimsWhitespace() {
        let input = "  SRR35517702  \n  SRR35517703  "
        let result = SRAAccessionParser.parseAccessionList(input)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testIsMultiAccessionInput() {
        XCTAssertTrue(SRAAccessionParser.isMultiAccessionInput("SRR111\nSRR222"))
        XCTAssertTrue(SRAAccessionParser.isMultiAccessionInput("SRR111, SRR222"))
        XCTAssertFalse(SRAAccessionParser.isMultiAccessionInput("SRR111"))
        XCTAssertFalse(SRAAccessionParser.isMultiAccessionInput("SARS-CoV-2"))
    }

    // MARK: - CSV Parsing

    func testParseCSVWithHeader() {
        let csv = "acc\nSRR35517702\nSRR35517703\nSRR35517705\n"
        let result = SRAAccessionParser.parseCSV(csv)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703", "SRR35517705"])
    }

    func testParseCSVWithoutHeader() {
        let csv = "SRR35517702\nSRR35517703\n"
        let result = SRAAccessionParser.parseCSV(csv)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testParseCSVWithEmptyLines() {
        let csv = "acc\n\nSRR35517702\n\nSRR35517703\n\n"
        let result = SRAAccessionParser.parseCSV(csv)
        XCTAssertEqual(result, ["SRR35517702", "SRR35517703"])
    }

    func testParseCSVFromFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let csvFile = tempDir.appendingPathComponent("test-accessions.csv")
        try "acc\nDRR028938\nDRR051810\n".write(to: csvFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: csvFile) }

        let result = try SRAAccessionParser.parseCSVFile(at: csvFile)
        XCTAssertEqual(result, ["DRR028938", "DRR051810"])
    }

    func testParseCSVFileWithInvalidAccessions() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let csvFile = tempDir.appendingPathComponent("test-mixed.csv")
        try "acc\nSRR123\njunk\nERR456\n".write(to: csvFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: csvFile) }

        let result = try SRAAccessionParser.parseCSVFile(at: csvFile)
        XCTAssertEqual(result, ["SRR123", "ERR456"])
    }
}
