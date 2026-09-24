// GenomicCoordinateDisplayTests.swift - stored 0-based half-open <-> displayed 1-based closed
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class GenomicCoordinateDisplayTests: XCTestCase {
    /// HBB in the GenBank record is `70545..72152`; the reader stores it as
    /// `[70544, 72152)`. The table must show the record's numbers back.
    func testHBBStoredIntervalDisplaysAsGenBankCoordinates() {
        let storedStart = 70_544
        let storedEnd = 72_152

        XCTAssertEqual(GenomicCoordinateDisplay.displayStart(storedStart), 70_545)
        XCTAssertEqual(GenomicCoordinateDisplay.displayEnd(storedEnd), 72_152)
        XCTAssertEqual(GenomicCoordinateDisplay.displayLength(storedStart: storedStart, storedEnd: storedEnd), 1_608)
        XCTAssertEqual(GenomicCoordinateDisplay.formattedStart(storedStart), "70,545")
        XCTAssertEqual(GenomicCoordinateDisplay.formattedEnd(storedEnd), "72,152")
    }

    func testDisplayMatchesGenomicRegionDisplayString() {
        let region = GenomicRegion(chromosome: "chr11", start: 70_544, end: 72_152)
        let expected = "chr11:\(GenomicCoordinateDisplay.formattedStart(region.start))-\(GenomicCoordinateDisplay.formattedEnd(region.end))"
        XCTAssertEqual(region.displayString, expected)
    }

    func testStoredConversionRoundTrips() {
        for stored in [0, 1, 99, 70_544, 1_000_000] {
            let shown = GenomicCoordinateDisplay.displayStart(stored)
            XCTAssertEqual(GenomicCoordinateDisplay.storedStart(fromDisplay: shown), stored)
        }
        for stored in [1, 100, 72_152] {
            let shown = GenomicCoordinateDisplay.displayEnd(stored)
            XCTAssertEqual(GenomicCoordinateDisplay.storedEnd(fromDisplay: shown), stored)
        }
    }

    func testUserTypedClosedRangeBecomesHalfOpen() {
        // A user typing 101-200 (1-based closed) means stored [100, 200).
        XCTAssertEqual(GenomicCoordinateDisplay.storedStart(fromDisplay: 101), 100)
        XCTAssertEqual(GenomicCoordinateDisplay.storedEnd(fromDisplay: 200), 200)
        // A single base at position 5 is stored [4, 5).
        XCTAssertEqual(GenomicCoordinateDisplay.storedStart(fromDisplay: 5), 4)
        XCTAssertEqual(GenomicCoordinateDisplay.storedEnd(fromDisplay: 5), 5)
    }

    func testFirstBaseDisplaysAsOneWithoutSeparator() {
        XCTAssertEqual(GenomicCoordinateDisplay.formattedStart(0), "1")
        XCTAssertEqual(GenomicCoordinateDisplay.formattedEnd(999), "999")
        XCTAssertEqual(GenomicCoordinateDisplay.formattedEnd(1_000), "1,000")
    }
}
