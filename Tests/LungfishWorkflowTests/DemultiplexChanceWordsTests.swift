// DemultiplexChanceWordsTests.swift - The limit line of the chance floor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Stable job lane DECOYWORDS, DEMUX-FLOOR-DECOY-MAX (ruling BIO-DECOY-MAX-STABLE, words set by UX in STB-R2-UX section D).
// A barcode that is not in the pool can still pass the chance floor and become a sample file with reads, in about one
// run in 1,000 for each such barcode. The app says so in words, and these tests pin the words byte for byte.

import XCTest
import LungfishWorkflow

final class DemultiplexChanceWordsTests: XCTestCase {
    /// A run that published no sample file has nothing to say about a barcode that is not in the pool.
    func testNotInPoolLimitIsNilWhenNoBarcodePassed() {
        XCTAssertNil(DemultiplexChanceWords.notInPoolLimit(publishedBarcodes: 0))
    }

    /// The line is the same for one published barcode and for several, and it keeps BIO's figure and the amplicon clause.
    func testNotInPoolLimitIsTheWholeLineWhenABarcodePassed() {
        let line = "A barcode that is not in your pool can still pass as a sample. For each such barcode this happens in "
            + "about one run in 1,000, and more often in amplicon files. Check samples with few reads against your "
            + "sample sheet."
        XCTAssertEqual(DemultiplexChanceWords.notInPoolLimit(publishedBarcodes: 1), line)
        XCTAssertEqual(DemultiplexChanceWords.notInPoolLimit(publishedBarcodes: 12), line)
    }
}
