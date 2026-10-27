// KrakenReadLengthTests.swift - The read check accepts every shape in which LGE runs kraken2 and draws its reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane READ-IDENTITY (BIO-READ-IDENTITY 4.1). Extract and BLAST compare the records they draw with the
// lengths kraken2 recorded. A valid result must never be refused, so each shape in which LGE runs kraken2 is pinned
// here as accepted, with one changed length beside it as refused. kraken2 2.17.1 run with --paired on mates of 40
// and 38 bases writes `40|38` under the fragment name, `/1` dropped.

import XCTest
import LungfishCore

final class KrakenReadLengthTests: XCTestCase {

    /// kraken2 --paired on R1 and R2 files, or on an interleaved file split in two: one `L|L` line a pair. Extract
    /// reads the mates of an interleaved file with no mate in their headers, in file order.
    func testAPairedLineAgreesWithBothMatesWhetherTheirHeadersNameAMateOrNot() {
        XCTAssertTrue(agree(lengths("40|38"), found([(1, 40), (2, 38)])))
        XCTAssertTrue(agree(lengths("40|38"), found([(nil, 40), (nil, 38)])))
        XCTAssertFalse(agree(lengths("40|38"), found([(nil, 40), (nil, 33)])))
    }

    /// kraken2 without --paired on interleaved pairs whose headers end ` 1:N` and ` 2:N`: two lines under one ID,
    /// one a mate, in file order. Extract sees no mate in the first word, and BLAST reads the marker.
    func testTwoLinesUnderOneIDAgreeWithTheMatesInOrder() {
        let expected = lengths("40") + lengths("38")
        XCTAssertTrue(agree(expected, found([(nil, 40), (nil, 38)])))
        XCTAssertTrue(agree(expected, found([(1, 40), (2, 38)])))
        XCTAssertFalse(agree(expected, found([(nil, 40), (nil, 30)])))
    }

    /// Only one mate's line names the taxon, and Extract and BLAST draw both mates by the fragment name.
    func testOneClassifiedMateAgreesWhenItsPairIsDrawn() {
        XCTAssertTrue(agree(lengths("38"), found([(nil, 40), (nil, 38)])))
        XCTAssertTrue(agree(lengths("38", mate: 2), found([(1, 40), (2, 38)])))
        XCTAssertFalse(agree(lengths("38", mate: 2), found([(1, 40), (2, 33)])))
    }

    /// `/1` and `/2` IDs in a run without --paired: each line names its mate, whatever order the records come in.
    func testMateSuffixesPairEachLineWithItsMate() {
        let expected = lengths("40", mate: 1) + lengths("38", mate: 2)
        XCTAssertTrue(agree(expected, found([(2, 38), (1, 40)])))
        XCTAssertFalse(agree(expected, found([(2, 40), (1, 38)])))
    }

    /// A merged read of a merge derivative, staged beside an empty mate (`L|0`), whose header may keep R1's `/1`.
    func testAMergedReadStagedBesideAnEmptyMateAgreesWithItsOneRecord() {
        XCTAssertEqual(lengths("250|0"), [KrakenReadLength(mate: nil, length: 250)])
        XCTAssertTrue(agree(lengths("250|0"), found([(nil, 250)])))
        XCTAssertTrue(agree(lengths("250|0"), found([(1, 250)])))
        XCTAssertFalse(agree(lengths("250|0"), found([(nil, 240)])))
    }

    /// A line whose length column cannot be read is checked by ID only: a record found passes, none found is missing.
    func testALineWithNoReadableLengthIsCheckedByIDOnly() {
        XCTAssertEqual(lengths("n/a"), [])
        var check = KrakenReadCheck()
        check.add(expected: lengths("n/a"), found: found([(nil, 12)]))
        check.add(expected: lengths("n/a"), found: [])
        XCTAssertEqual([check.named, check.missing, check.otherLength], [2, 1, 0])
    }

    private func lengths(_ column: String, mate: Int? = nil) -> [KrakenReadLength] {
        KrakenReadLength.lengths(column: column, mateInID: mate)
    }

    private func found(_ records: [(Int?, Int)]) -> [KrakenReadLength] {
        records.map { KrakenReadLength(mate: $0.0, length: $0.1) }
    }

    private func agree(_ expected: [KrakenReadLength], _ found: [KrakenReadLength]) -> Bool {
        KrakenReadLength.agree(expected: expected, found: found)
    }
}
