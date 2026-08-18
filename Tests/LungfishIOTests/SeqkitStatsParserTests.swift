// SeqkitStatsParserTests.swift - Tests for header-driven seqkit stats parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Tests for ``SeqkitStatsParser``.
///
/// The parser is header-driven so that a seqkit upgrade that adds, removes, or
/// reorders columns surfaces as a clear error (or is tolerated) rather than
/// silently producing wrong numbers from fixed positional indices.
final class SeqkitStatsParserTests: XCTestCase {

    // MARK: - Header-Driven Parsing

    func testParsesByHeaderName() throws {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\tQ1\tQ2\tQ3\tsum_gap\tN50\tQ20(%)\tQ30(%)\tAvgQual\tGC(%)\n" +
                   "r.fq\tFASTQ\tDNA\t22\t3300\t150\t150.0\t150\t150\t150\t150\t0\t150\t98.1\t95.2\t35.9\t38.0\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.numSeqs, 22)
        XCTAssertEqual(t.avgLen, 150.0, accuracy: 0.001)
        XCTAssertEqual(t.gcPercent, 38.0)
        XCTAssertEqual(t.file, "r.fq")
        XCTAssertEqual(t.sumLen, 3300)
        XCTAssertEqual(t.minLen, 150)
        XCTAssertEqual(t.maxLen, 150)
        XCTAssertEqual(t.q2, 150.0)
        XCTAssertEqual(t.n50, 150.0)
        XCTAssertEqual(t.sumGap, 0.0)
        XCTAssertEqual(t.q20Percent, 98.1)
        XCTAssertEqual(t.q30Percent, 95.2)
        XCTAssertEqual(t.avgQual, 35.9)
    }

    func testColumnReorderStillParses() throws {
        let text = "num_seqs\tfile\tavg_len\n5\tx\t10.5\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.numSeqs, 5)
        XCTAssertEqual(t.avgLen, 10.5)
        XCTAssertEqual(t.file, "x")
    }

    /// An upstream seqkit release that appends a new column must not break parsing.
    func testUnknownExtraColumnIsIgnored() throws {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\tbrand_new_column\n" +
                   "r.fq\tFASTQ\tDNA\t7\t700\t100\t100.0\t100\tsomething\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.numSeqs, 7)
        XCTAssertEqual(t.sumLen, 700)
    }

    // MARK: - Optional Columns

    func testOptionalColumnsAreNilWhenAbsent() throws {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\n" +
                   "r.fq\tFASTQ\tDNA\t3\t300\t100\t100.0\t100\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertNil(t.q20Percent)
        XCTAssertNil(t.q30Percent)
        XCTAssertNil(t.avgQual)
        XCTAssertNil(t.gcPercent)
        XCTAssertNil(t.n50)
        XCTAssertNil(t.q1)
        XCTAssertNil(t.q2)
        XCTAssertNil(t.q3)
        XCTAssertNil(t.sumGap)
    }

    /// seqkit emits `-nan` / `NA` for quality columns on FASTA input.
    func testNonNumericOptionalValuesBecomeNil() throws {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\tQ20(%)\tAvgQual\n" +
                   "r.fa\tFASTA\tDNA\t3\t300\t100\t100.0\t100\tNA\t-nan\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.numSeqs, 3)
        XCTAssertNil(t.q20Percent)
        XCTAssertNil(t.avgQual)
    }

    /// seqkit writes thousands separators unless `-T` is passed; tolerate them.
    func testCommaGroupedNumbersParse() throws {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\n" +
                   "r.fq\tFASTQ\tDNA\t1,234\t123,400\t100\t100.0\t100\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.numSeqs, 1234)
        XCTAssertEqual(t.sumLen, 123_400)
    }

    // MARK: - Error Cases

    /// `sumLen` is Int64 so a large run's total base count does not overflow.
    func testLargeSumLenExceeds32BitRange() throws {
        let text = "file\tnum_seqs\tsum_len\n" +
                   "big.fq\t1000000\t9000000000\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.sumLen, 9_000_000_000)
    }

    func testMissingNumSeqsThrows() {
        let text = "file\tformat\ttype\tsum_len\n" +
                   "r.fq\tFASTQ\tDNA\t300\n"
        XCTAssertThrowsError(try SeqkitStatsParser.parse(text)) { error in
            XCTAssertTrue("\(error)".contains("num_seqs"), "Expected error naming num_seqs, got: \(error)")
        }
    }

    func testNonNumericNumSeqsThrows() {
        let text = "file\tnum_seqs\n" +
                   "r.fq\tnot-a-number\n"
        XCTAssertThrowsError(try SeqkitStatsParser.parse(text)) { error in
            XCTAssertTrue("\(error)".contains("num_seqs"), "Expected error naming num_seqs, got: \(error)")
        }
    }

    func testEmptyOutputThrows() {
        XCTAssertThrowsError(try SeqkitStatsParser.parse(""))
    }

    func testHeaderWithoutDataRowThrows() {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\n"
        XCTAssertThrowsError(try SeqkitStatsParser.parse(text))
    }

    func testHeaderValueCountMismatchThrows() {
        let text = "file\tformat\tnum_seqs\n" +
                   "r.fq\tFASTQ\n"
        XCTAssertThrowsError(try SeqkitStatsParser.parse(text))
    }

    // MARK: - Multiple Rows

    func testParseAllReturnsEveryDataRow() throws {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\n" +
                   "a.fq\tFASTQ\tDNA\t10\t1000\t100\t100.0\t100\n" +
                   "b.fq\tFASTQ\tDNA\t20\t2000\t100\t100.0\t100\n"
        let rows = try SeqkitStatsParser.parseAll(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].file, "a.fq")
        XCTAssertEqual(rows[0].numSeqs, 10)
        XCTAssertEqual(rows[1].file, "b.fq")
        XCTAssertEqual(rows[1].numSeqs, 20)
    }

    func testParseReturnsFirstDataRowWhenMultiplePresent() throws {
        let text = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\n" +
                   "a.fq\tFASTQ\tDNA\t10\t1000\t100\t100.0\t100\n" +
                   "b.fq\tFASTQ\tDNA\t20\t2000\t100\t100.0\t100\n"
        let t = try SeqkitStatsParser.parse(text)
        XCTAssertEqual(t.file, "a.fq")
        XCTAssertEqual(t.numSeqs, 10)
    }
}
