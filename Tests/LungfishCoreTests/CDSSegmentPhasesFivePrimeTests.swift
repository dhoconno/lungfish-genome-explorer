// CDSSegmentPhasesFivePrimeTests.swift - The phases of a CDS whose 5' segment has a phase
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.65 (BIO ruling on 13.65 R5). A segment's phase is ((p - c) mod 3), with p the 5' segment's phase
// and c the coding length before the segment in transcription order.

import XCTest
@testable import LungfishCore

final class CDSSegmentPhasesFivePrimeTests: XCTestCase {
    private func phases(_ ranges: [Range<Int>], _ strand: String, _ fivePrimePhase: Int) -> [Int] {
        CDSSegmentPhases.compute(
            intervals: ranges.map { CDSSegmentPhases.Interval(start: $0.lowerBound, end: $0.upperBound) },
            strand: strand, fivePrimePhase: fivePrimePhase
        ).map(\.phase)
    }

    /// The `chrR` CDS of the ruling. Its 5' segment [10,18) keeps phase 1, and [2,7), 8 bases later, takes
    /// (1 - 8) mod 3 = 2. The pairs come in genomic order.
    func testAReverseCDSKeepsItsFivePrimePhase() {
        XCTAssertEqual(phases([2..<7, 10..<18], "-", 1), [2, 1])
    }

    /// A forward CDS of 10 and 20 bases with 5' phase 1: the second segment takes (1 - 10) mod 3 = 0.
    func testAForwardCDSKeepsItsFivePrimePhase() {
        XCTAssertEqual(phases([0..<10, 20..<40], "+", 1), [1, 0])
    }

    /// Phase 0, the default, gives today's phases, and a phase outside 0 to 2 is taken as 0.
    func testPhaseZeroAndOutOfRangePhasesKeepTodaysPhases() {
        XCTAssertEqual(phases([0..<10, 20..<40], "+", 0), [0, 2])
        XCTAssertEqual(phases([0..<10, 20..<40], "+", 3), [0, 2])
        XCTAssertEqual(phases([0..<10, 20..<40], "+", -1), [0, 2])
    }
}
