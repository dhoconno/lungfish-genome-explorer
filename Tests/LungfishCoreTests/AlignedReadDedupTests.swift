// AlignedReadDedupTests.swift - Tests for shared AlignedRead deduplication
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class AlignedReadDedupTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a minimal AlignedRead for dedup testing.
    private func makeRead(
        position: Int,
        length: Int,
        isReverse: Bool = false
    ) -> AlignedRead {
        let flag: UInt16 = isReverse ? 0x10 : 0
        let cigar = length > 0 ? [CIGAROperation(op: .match, length: length)] : []
        let seq = String(repeating: "A", count: max(1, length))
        let quals = [UInt8](repeating: 40, count: max(1, length))
        return AlignedRead(
            name: "read",
            flag: flag,
            chromosome: "chr1",
            position: position,
            mapq: 60,
            cigar: cigar,
            sequence: seq,
            qualities: quals
        )
    }

    // MARK: - Empty and Single Read

    func testEmptyReads() {
        let result = AlignedRead.deduplicatedReadCount(from: [])
        XCTAssertEqual(result, 0)
    }

    func testSingleRead() {
        let reads = [makeRead(position: 100, length: 100)]
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 1)
    }

    // MARK: - No Duplicates

    func testAllUniquePositions() {
        let reads = [
            makeRead(position: 100, length: 100),
            makeRead(position: 200, length: 100),
            makeRead(position: 300, length: 100),
        ]
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 3)
    }

    func testSamePositionDifferentStrand() {
        // Same start/end but different strand = not duplicates
        let reads = [
            makeRead(position: 100, length: 100, isReverse: false),
            makeRead(position: 100, length: 100, isReverse: true),
        ]
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 2)
    }

    func testSameStartDifferentLength() {
        let reads = [
            makeRead(position: 100, length: 100),
            makeRead(position: 100, length: 150),
        ]
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 2)
    }

    // MARK: - Duplicates

    func testTwoDuplicates() {
        let reads = [
            makeRead(position: 100, length: 100),
            makeRead(position: 100, length: 100),
        ]
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 1)
    }

    func testThreeDuplicates() {
        let reads = [
            makeRead(position: 100, length: 100),
            makeRead(position: 100, length: 100),
            makeRead(position: 100, length: 100),
        ]
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 1)
    }

    func testMixedDuplicatesAndUniques() {
        let reads = [
            makeRead(position: 100, length: 100), // group A (3 dupes -> 1 unique)
            makeRead(position: 100, length: 100),
            makeRead(position: 100, length: 100),
            makeRead(position: 300, length: 100), // group B (1 unique)
            makeRead(position: 500, length: 100), // group C (2 dupes -> 1 unique)
            makeRead(position: 500, length: 100),
        ]
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 3)
    }

    // MARK: - Boundary Cases

    func testZeroLengthAlignment() {
        // CIGAR with no ref-consuming ops -> alignmentEnd == position
        let read1 = AlignedRead(
            name: "r1", flag: 0, chromosome: "chr1", position: 100, mapq: 60,
            cigar: [CIGAROperation(op: .softClip, length: 50)],
            sequence: String(repeating: "A", count: 50),
            qualities: [UInt8](repeating: 40, count: 50)
        )
        let read2 = AlignedRead(
            name: "r2", flag: 0, chromosome: "chr1", position: 100, mapq: 60,
            cigar: [CIGAROperation(op: .softClip, length: 50)],
            sequence: String(repeating: "A", count: 50),
            qualities: [UInt8](repeating: 40, count: 50)
        )
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: [read1, read2]), 1)
    }

    func testLargeContigFewReads() {
        let reads = [
            makeRead(position: 0, length: 150),
            makeRead(position: 1_000_000, length: 150),
        ]
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 2)
    }

    func testAllDuplicates() {
        let reads = (0..<100).map { _ in
            makeRead(position: 42, length: 150)
        }
        XCTAssertEqual(AlignedRead.deduplicatedReadCount(from: reads), 1)
    }

    // MARK: - Result Is Never Negative

    func testResultNeverNegative() {
        let reads = [makeRead(position: 0, length: 100)]
        let result = AlignedRead.deduplicatedReadCount(from: reads)
        XCTAssertGreaterThanOrEqual(result, 0)
    }
}
