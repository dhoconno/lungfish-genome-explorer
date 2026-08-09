// AlignedReadFASTAFormatterTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Item 3 (mapping viewer fixes, 2026-08-09): formatter tests for multi-read
// aligned-orientation FASTA export from the read-selection context menu.
// Per spec bio gate:
//   - Header: >{QNAME} {RNAME}:{1-based start}-{end} strand={+|-} cigar={CIGAR} mapq={MAPQ}
//     with `hardclipped={N}` appended when CIGAR has H ops.
//   - Body: AlignedRead.sequence verbatim (soft clips included, hard clips absent).
//   - Reads with empty or "*" sequence (secondary alignments) are skipped; the
//     skip count is returned to the caller.

import XCTest
@testable import LungfishKit
import LungfishCore

final class AlignedReadFASTAFormatterTests: XCTestCase {
    private func makeRead(
        name: String = "read-1",
        flag: UInt16 = 0,
        chromosome: String = "NC_001",
        position: Int = 100,
        mapq: UInt8 = 60,
        cigarString: String = "10M",
        sequence: String = "ACGTACGTAC",
        qualities: [UInt8]? = nil
    ) -> AlignedRead {
        let cigar = CIGAROperation.parse(cigarString) ?? []
        let quals = qualities ?? Array(repeating: UInt8(30), count: sequence.count)
        return AlignedRead(
            name: name,
            flag: flag,
            chromosome: chromosome,
            position: position,
            mapq: mapq,
            cigar: cigar,
            sequence: sequence,
            qualities: quals
        )
    }

    // MARK: - Single-read header/body shape

    func testForwardStrandReadHeaderAndBody() {
        let read = makeRead(
            name: "readA",
            flag: 0,
            chromosome: "chr1",
            position: 99, // 0-based
            mapq: 42,
            cigarString: "10M",
            sequence: "ACGTACGTAC"
        )

        let result = AlignedReadFASTAFormatter.format([read])

        // 0-based position 99 -> 1-based start 100; alignmentEnd = 99+10 = 109 -> 1-based inclusive end 109.
        XCTAssertEqual(
            result.fasta,
            ">readA chr1:100-109 strand=+ cigar=10M mapq=42\nACGTACGTAC"
        )
        XCTAssertEqual(result.skippedCount, 0)
    }

    func testReverseStrandReadHasMinusStrandInHeader() {
        let read = makeRead(flag: 0x10, cigarString: "10M")

        let result = AlignedReadFASTAFormatter.format([read])

        XCTAssertTrue(result.fasta.contains("strand=-"), "Expected strand=- in header, got: \(result.fasta)")
    }

    // MARK: - Soft clips included, hard clips absent + annotated

    func testSoftClippedReadBodyLengthIncludesClippedBases() {
        // 10S80M10S: SEQ contains all 100 bases (soft clips are present in SEQ per SAM spec).
        let sequence = String(repeating: "A", count: 100)
        let read = makeRead(cigarString: "10S80M10S", sequence: sequence)

        let result = AlignedReadFASTAFormatter.format([read])
        let body = result.fasta.split(separator: "\n", maxSplits: 1)[1]

        XCTAssertEqual(body.count, 100)
        XCTAssertFalse(result.fasta.contains("hardclipped="))
    }

    func testHardClippedReadAnnotatesHeaderWithTotalHardClippedBases() {
        // 5H90M5H: SEQ contains only the 90 aligned bases (hard clips absent from SEQ).
        let sequence = String(repeating: "C", count: 90)
        let read = makeRead(cigarString: "5H90M5H", sequence: sequence)

        let result = AlignedReadFASTAFormatter.format([read])

        XCTAssertTrue(
            result.fasta.contains("hardclipped=10"),
            "Expected hardclipped=10 (5+5) in header, got: \(result.fasta)"
        )
        let body = result.fasta.split(separator: "\n", maxSplits: 1)[1]
        XCTAssertEqual(body.count, 90)
    }

    // MARK: - Skip empty/"*" SEQ (secondary alignments)

    func testEmptySequenceReadIsSkippedAndCounted() {
        let read = makeRead(sequence: "", qualities: [])

        let result = AlignedReadFASTAFormatter.format([read])

        XCTAssertEqual(result.fasta, "")
        XCTAssertEqual(result.skippedCount, 1)
    }

    func testAsteriskSequenceReadIsSkippedAndCounted() {
        let read = makeRead(sequence: "*", qualities: [0])

        let result = AlignedReadFASTAFormatter.format([read])

        XCTAssertEqual(result.fasta, "")
        XCTAssertEqual(result.skippedCount, 1)
    }

    // MARK: - Multi-read

    func testMultiReadFASTAJoinsRecordsWithNewlineAndSkipsOnlyInvalidOnes() {
        let good1 = makeRead(name: "readA", position: 0, cigarString: "4M", sequence: "ACGT")
        let bad = makeRead(name: "readB", sequence: "*", qualities: [0])
        let good2 = makeRead(name: "readC", position: 4, cigarString: "4M", sequence: "TTTT")

        let result = AlignedReadFASTAFormatter.format([good1, bad, good2])

        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(result.fasta.contains(">readA"))
        XCTAssertTrue(result.fasta.contains(">readC"))
        XCTAssertFalse(result.fasta.contains(">readB"))
        // Two records, each two lines, joined by a single blank-free newline between records.
        let records = result.fasta.components(separatedBy: "\n>")
        XCTAssertEqual(records.count, 2)
    }

    func testAllReadsSkippedProducesEmptyFASTAWithFullSkipCount() {
        let bad1 = makeRead(name: "readA", sequence: "", qualities: [])
        let bad2 = makeRead(name: "readB", sequence: "*", qualities: [0])

        let result = AlignedReadFASTAFormatter.format([bad1, bad2])

        XCTAssertEqual(result.fasta, "")
        XCTAssertEqual(result.skippedCount, 2)
    }
}
