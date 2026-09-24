// LocusQueryParserTests.swift - Tests for the shared locus grammar (SCI-13/FEA-09)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class GenomicRegionDisplayStringTests: XCTestCase {

    func testDisplayStringIsOneBasedClosed() {
        // 0-based half-open [1000,2000) -> 1-based closed [1001,2000]
        let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
        XCTAssertEqual(region.displayString, "chr1:1,001-2,000")
    }

    func testDisplayStringAddsThousandsSeparators() {
        let region = GenomicRegion(chromosome: "chr1", start: 200_000_000, end: 248_956_422)
        XCTAssertEqual(region.displayString, "chr1:200,000,001-248,956,422")
    }

    func testDisplayStringSingleBaseOmitsRange() {
        // 0-based half-open [999,1000) is a single base: 1-based position 1000.
        let region = GenomicRegion(chromosome: "chr1", start: 999, end: 1000)
        XCTAssertEqual(region.displayString, "chr1:1,000")
    }

    func testDisplayStringRoundTripsThroughLocusQueryParser() throws {
        let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
        let display = region.displayString
        let parsed = try LocusQueryParser.parse(display)
        guard case .range(let chromosome, let start, let end) = parsed else {
            XCTFail("Expected a range query")
            return
        }
        XCTAssertEqual(chromosome, "chr1")
        // Parser returns 1-based values as typed; convert back to 0-based half-open.
        XCTAssertEqual(start - 1, region.start)
        XCTAssertEqual(end, region.end)
    }
}

final class LocusQueryParserTests: XCTestCase {

    // MARK: - Bare chromosome

    func testBareChromosomeName() throws {
        let result = try LocusQueryParser.parse("chr2")
        XCTAssertEqual(result, .chromosome(name: "chr2"))
    }

    func testBareChromosomeNameWithHyphenIsNotMisparsedAsRange() throws {
        // A contig name like "scaffold-12" contains a hyphen but no digits on
        // one side, so it must not be treated as a numeric range.
        let result = try LocusQueryParser.parse("scaffold-12")
        XCTAssertEqual(result, .chromosome(name: "scaffold-12"))
    }

    // MARK: - Bare position / range (no chromosome)

    func testBarePosition() throws {
        let result = try LocusQueryParser.parse("1000")
        XCTAssertEqual(result, .position(chromosome: nil, position: 1000))
    }

    func testBareRangeWithHyphen() throws {
        let result = try LocusQueryParser.parse("1000-2000")
        XCTAssertEqual(result, .range(chromosome: nil, start: 1000, end: 2000))
    }

    func testBareRangeWithDoubleDot() throws {
        let result = try LocusQueryParser.parse("1000..2000")
        XCTAssertEqual(result, .range(chromosome: nil, start: 1000, end: 2000))
    }

    // MARK: - Chromosome + position/range

    func testChromosomeAndPosition() throws {
        let result = try LocusQueryParser.parse("chr1:1000")
        XCTAssertEqual(result, .position(chromosome: "chr1", position: 1000))
    }

    func testChromosomeAndRangeWithHyphen() throws {
        let result = try LocusQueryParser.parse("chr1:1000-2000")
        XCTAssertEqual(result, .range(chromosome: "chr1", start: 1000, end: 2000))
    }

    func testChromosomeAndRangeWithDoubleDot() throws {
        let result = try LocusQueryParser.parse("chr1:1000..2000")
        XCTAssertEqual(result, .range(chromosome: "chr1", start: 1000, end: 2000))
    }

    // MARK: - Comma-separated thousands (what the ruler displays)

    func testStripsThousandsSeparatorCommas() throws {
        let result = try LocusQueryParser.parse("chr1:1,000-2,000")
        XCTAssertEqual(result, .range(chromosome: "chr1", start: 1000, end: 2000))
    }

    func testRulerDisplayStringParsesBack() throws {
        // Exact acceptance test from the audit: the ruler shows this string,
        // and Go to Location must accept it.
        let result = try LocusQueryParser.parse("chr1:1,001-2,000")
        XCTAssertEqual(result, .range(chromosome: "chr1", start: 1001, end: 2000))
    }

    // MARK: - Whitespace tolerance

    func testTrimsWhitespace() throws {
        let result = try LocusQueryParser.parse("  chr1:1000-2000  ")
        XCTAssertEqual(result, .range(chromosome: "chr1", start: 1000, end: 2000))
    }

    // MARK: - Contig names containing colons

    func testContigNameWithColonsMatchedByKnownChromosomes() throws {
        let known = ["HLA-A*01:01:01:01"]
        let result = try LocusQueryParser.parse("HLA-A*01:01:01:01:100-200", knownChromosomes: known)
        XCTAssertEqual(result, .range(chromosome: "HLA-A*01:01:01:01", start: 100, end: 200))
    }

    func testContigNameWithColonsPrefersLongestMatch() throws {
        let known = ["chr1", "chr1:extra"]
        let result = try LocusQueryParser.parse("chr1:extra:100", knownChromosomes: known)
        XCTAssertEqual(result, .position(chromosome: "chr1:extra", position: 100))
    }

    func testFallsBackToFirstColonWithoutKnownChromosomes() {
        // Without a known-chromosome list, historical behavior splits on the
        // first colon, which misparses an HLA-style contig's remaining
        // colon-separated segments as a position/range. This should throw
        // rather than silently succeed with a wrong split, documenting that
        // `knownChromosomes` is required to address such a contig correctly.
        XCTAssertThrowsError(try LocusQueryParser.parse("HLA-A*01:01:01:01:100-200"))
    }

    // MARK: - Error cases

    func testEmptyStringThrows() {
        XCTAssertThrowsError(try LocusQueryParser.parse("")) { error in
            XCTAssertEqual(error as? LocusQueryError, .empty)
        }
    }

    func testWhitespaceOnlyThrows() {
        XCTAssertThrowsError(try LocusQueryParser.parse("   "))
    }

    func testInvertedRangeThrows() {
        XCTAssertThrowsError(try LocusQueryParser.parse("chr1:2000-1000")) { error in
            XCTAssertEqual(error as? LocusQueryError, .invalidRange(start: 2000, end: 1000))
        }
    }

    func testGarbageAfterColonThrows() {
        XCTAssertThrowsError(try LocusQueryParser.parse("chr1:notanumber"))
    }

    func testEmptyChromosomeThrows() {
        XCTAssertThrowsError(try LocusQueryParser.parse(":1000"))
    }
}
