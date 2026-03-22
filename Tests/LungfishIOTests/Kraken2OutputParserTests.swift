// Kraken2OutputParserTests.swift - Tests for Kraken2 per-read classification output parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class Kraken2OutputParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseClassifiedRead() throws {
        let text = "C\tread1\t9606\t150\t0:1 9606:120 0:29\n"

        let records = try Kraken2OutputParser.parse(text: text)

        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].isClassified)
        XCTAssertEqual(records[0].readId, "read1")
        XCTAssertEqual(records[0].taxId, 9606)
        XCTAssertEqual(records[0].readLength, 150)
        XCTAssertEqual(records[0].kmerHits.count, 3)

        // Verify k-mer hits
        XCTAssertEqual(records[0].kmerHits[0].taxId, 0)
        XCTAssertEqual(records[0].kmerHits[0].count, 1)
        XCTAssertEqual(records[0].kmerHits[1].taxId, 9606)
        XCTAssertEqual(records[0].kmerHits[1].count, 120)
        XCTAssertEqual(records[0].kmerHits[2].taxId, 0)
        XCTAssertEqual(records[0].kmerHits[2].count, 29)
    }

    func testParseUnclassifiedRead() throws {
        let text = "U\tread2\t0\t150\t0:150\n"

        let records = try Kraken2OutputParser.parse(text: text)

        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].isClassified)
        XCTAssertEqual(records[0].readId, "read2")
        XCTAssertEqual(records[0].taxId, 0)
        XCTAssertEqual(records[0].readLength, 150)
    }

    func testParseMultipleReads() throws {
        let text = """
        C\tread1\t9606\t150\t0:1 9606:120 0:29
        U\tread2\t0\t150\t0:150
        C\tread3\t562\t200\t562:180 0:20
        C\tread4\t287\t100\t287:80 0:20
        """

        let records = try Kraken2OutputParser.parse(text: text)

        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records[0].isClassified)
        XCTAssertFalse(records[1].isClassified)
        XCTAssertTrue(records[2].isClassified)
        XCTAssertTrue(records[3].isClassified)
    }

    // MARK: - Paired-End Reads

    func testParsePairedEndReadLength() throws {
        // Kraken2 outputs "len1|len2" for paired-end reads
        let text = "C\tread1\t9606\t150|150\t0:1 9606:120 0:29\n"

        let records = try Kraken2OutputParser.parse(text: text)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].readLength, 300) // 150 + 150
    }

    // MARK: - Ambiguous K-mers

    func testParseAmbiguousKmers() throws {
        // "A" represents ambiguous k-mers
        let text = "C\tread1\t562\t150\tA:5 562:100 A:10 0:35\n"

        let records = try Kraken2OutputParser.parse(text: text)

        XCTAssertEqual(records.count, 1)
        // Ambiguous k-mers mapped to taxId 0
        XCTAssertEqual(records[0].kmerHits[0].taxId, 0)
        XCTAssertEqual(records[0].kmerHits[0].count, 5)
        XCTAssertEqual(records[0].kmerHits[1].taxId, 562)
        XCTAssertEqual(records[0].kmerHits[1].count, 100)
    }

    // MARK: - Error Handling

    func testParseEmptyFileThrows() {
        XCTAssertThrowsError(try Kraken2OutputParser.parse(text: "")) { error in
            XCTAssertTrue(error is Kraken2OutputParserError)
        }
    }

    func testMalformedLineSkipped() throws {
        let text = """
        C\tread1\t9606\t150\t0:1 9606:120 0:29
        this is not valid
        C\tread2\t562\t200\t562:180 0:20
        """

        let records = try Kraken2OutputParser.parse(text: text)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].readId, "read1")
        XCTAssertEqual(records[1].readId, "read2")
    }

    func testInvalidStatusSkipped() throws {
        let text = """
        C\tread1\t9606\t150\t9606:150
        X\tread2\t0\t100\t0:100
        U\tread3\t0\t150\t0:150
        """

        let records = try Kraken2OutputParser.parse(text: text)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].readId, "read1")
        XCTAssertEqual(records[1].readId, "read3")
    }

    // MARK: - Filtering

    func testReadIdsClassifiedToTaxId() throws {
        let text = """
        C\tread1\t9606\t150\t9606:150
        C\tread2\t562\t200\t562:200
        U\tread3\t0\t150\t0:150
        C\tread4\t562\t180\t562:180
        C\tread5\t9606\t150\t9606:150
        """

        let records = try Kraken2OutputParser.parse(text: text)

        let humanReads = Kraken2OutputParser.readIds(from: records, classifiedTo: 9606)
        XCTAssertEqual(humanReads, ["read1", "read5"])

        let ecoliReads = Kraken2OutputParser.readIds(from: records, classifiedTo: 562)
        XCTAssertEqual(ecoliReads, ["read2", "read4"])

        let unclassifiedReads = Kraken2OutputParser.readIds(from: records, classifiedTo: 0)
        XCTAssertEqual(unclassifiedReads, ["read3"])

        let noReads = Kraken2OutputParser.readIds(from: records, classifiedTo: 99999)
        XCTAssertTrue(noReads.isEmpty)
    }

    func testReadIdsClassifiedToAnyOfTaxIds() throws {
        let text = """
        C\tread1\t9606\t150\t9606:150
        C\tread2\t562\t200\t562:200
        U\tread3\t0\t150\t0:150
        C\tread4\t287\t180\t287:180
        C\tread5\t562\t150\t562:150
        """

        let records = try Kraken2OutputParser.parse(text: text)

        let cladeReads = Kraken2OutputParser.readIds(
            from: records,
            classifiedToAnyOf: Set([562, 287])
        )
        XCTAssertEqual(Set(cladeReads), Set(["read2", "read4", "read5"]))
    }

    // MARK: - K-mer Hit Parsing

    func testKmerHitParsing() {
        let hits = Kraken2OutputParser.parseKmerHits("0:1 9606:120 0:29")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].taxId, 0)
        XCTAssertEqual(hits[0].count, 1)
        XCTAssertEqual(hits[1].taxId, 9606)
        XCTAssertEqual(hits[1].count, 120)
        XCTAssertEqual(hits[2].taxId, 0)
        XCTAssertEqual(hits[2].count, 29)
    }

    func testKmerHitParsingEmpty() {
        let hits = Kraken2OutputParser.parseKmerHits("")
        XCTAssertTrue(hits.isEmpty)
    }

    func testKmerHitParsingMalformed() {
        // Tokens without colons should be skipped
        let hits = Kraken2OutputParser.parseKmerHits("9606:120 badtoken 0:29")
        XCTAssertEqual(hits.count, 2)
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions() {
        let emptyErr = Kraken2OutputParserError.emptyFile
        XCTAssertNotNil(emptyErr.errorDescription)
        XCTAssertTrue(emptyErr.errorDescription!.contains("Empty"))

        let fileErr = Kraken2OutputParserError.fileReadError(
            URL(fileURLWithPath: "/tmp/test.output"),
            "Permission denied"
        )
        XCTAssertNotNil(fileErr.errorDescription)
        XCTAssertTrue(fileErr.errorDescription!.contains("test.output"))
    }
}
