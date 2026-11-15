// MatrixMarketReaderTests.swift - The one Matrix Market reader of single-cell imports (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The reader streams `%%MatrixMarket matrix coordinate integer general` from a plain file or through gzip, and refuses
// every other header and every value that is not an unsigned decimal integer in words with the field `matrix`
// (`SCR/rulings/ARCH-SCHEMA-SPIKE.md` B5). The pins are the cut's own counts (`Tests/Fixtures/rnaseq/README.md:19`).

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO

final class MatrixMarketReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "matrix-market") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private static var cellRangerFiltered: URL {
        RNASeqFixtures.root.appendingPathComponent("cellranger-pbmc_1k_v3/outs/filtered_feature_bc_matrix", isDirectory: true)
    }

    private static let integerWords = "and LGE counts whole unique UMIs a cell. Import the folder's integer matrix, such as Solo.out/Gene/filtered/matrix.mtx."

    private func write(_ text: String, named name: String = "matrix.mtx") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Every entry of `url`, read in batches of `capacity`, and the reader's size line.
    private func readAll(_ url: URL, capacity: Int = 1000) throws -> (MatrixMarketSize, entries: Int, sum: UInt64, isGzip: Bool) {
        let reader = try MatrixMarketReader(url: url)
        defer { reader.close() }
        var batch = MatrixMarketBatch(capacity: capacity)
        var entries = 0
        var sum: UInt64 = 0
        while try reader.next(&batch) {
            XCTAssertLessThanOrEqual(batch.count, capacity)
            entries += batch.count
            for index in 0..<batch.count { sum += batch.values[index] }
        }
        return (reader.size, entries, sum, reader.isGzip)
    }

    private func refusal(_ url: URL, file: StaticString = #filePath, line: UInt = #line) -> MatrixMarketError? {
        do {
            _ = try readAll(url)
            XCTFail("the matrix was read", file: file, line: line)
            return nil
        } catch let error as MatrixMarketError {
            XCTAssertEqual(error.field, "matrix", file: file, line: line)
            return error
        } catch {
            XCTFail("another error: \(error)", file: file, line: line)
            return nil
        }
    }

    func testTheSTARsoloCutReadsItsEntriesAndUMIs() throws {
        let read = try readAll(RNASeqFixtures.starsoloFiltered.appendingPathComponent("matrix.mtx"), capacity: 997)
        XCTAssertEqual(read.0, MatrixMarketSize(rows: 1_353, columns: 200, entries: 17_692))
        XCTAssertEqual(read.entries, 17_692)
        XCTAssertEqual(read.sum, 212_629)
        XCTAssertFalse(read.isGzip)
    }

    func testTheCellRangerCutReadsThroughGzip() throws {
        let read = try readAll(Self.cellRangerFiltered.appendingPathComponent("matrix.mtx.gz"))
        XCTAssertEqual(read.0, MatrixMarketSize(rows: 1_353, columns: 200, entries: 17_708))
        XCTAssertEqual(read.entries, 17_708)
        XCTAssertEqual(read.sum, 212_733)
        XCTAssertTrue(read.isGzip)
    }

    func testTextLinesReadPlainAndGzipFiles() throws {
        let plain = try MatrixMarketReader.textLines(of: RNASeqFixtures.starsoloFiltered.appendingPathComponent("barcodes.tsv"))
        let gzip = try MatrixMarketReader.textLines(of: Self.cellRangerFiltered.appendingPathComponent("barcodes.tsv.gz"))
        XCTAssertEqual(plain.count, 200)
        XCTAssertEqual(gzip.count, 200)
        XCTAssertEqual(gzip.map { String($0.dropLast(2)) }, plain, "10x writes the same barcodes with -1")
    }

    func testARealHeaderIsRefusedInWords() throws {
        let header = "%%MatrixMarket matrix coordinate real general"
        let url = try write("\(header)\n2 2 1\n1 1 1.0\n")
        XCTAssertEqual(refusal(url)?.errorDescription, "This matrix holds real values (\(header)), \(Self.integerWords)")
    }

    func testAPatternHeaderIsRefusedInWords() throws {
        let header = "%%MatrixMarket matrix coordinate pattern general"
        let url = try write("\(header)\n2 2 1\n1 1\n")
        XCTAssertEqual(refusal(url)?.errorDescription, "This matrix holds pattern values (\(header)), \(Self.integerWords)")
    }

    func testADecimalValueUnderAnIntegerHeaderIsRefusedAndNeverRounded() throws {
        let url = try write("%%MatrixMarket matrix coordinate integer general\n%\n2 2 2\n1 1 3\n2 1 1.5\n")
        XCTAssertEqual(
            refusal(url)?.errorDescription,
            "This matrix holds decimal values (line 5 of matrix.mtx reads 2 1 1.5), \(Self.integerWords)")
        let signed = try write("%%MatrixMarket matrix coordinate integer general\n2 2 1\n1 1 -1\n", named: "signed.mtx")
        XCTAssertEqual(
            refusal(signed)?.errorDescription,
            "This matrix holds signed values (line 3 of signed.mtx reads 1 1 -1), \(Self.integerWords)")
    }

    func testAnArrayHeaderIsRefusedInWords() throws {
        let header = "%%MatrixMarket matrix array integer general"
        let url = try write("\(header)\n2 2\n1\n2\n3\n4\n")
        XCTAssertEqual(refusal(url)?.errorDescription, "This matrix holds array values (\(header)), \(Self.integerWords)")
    }

    func testAnEntryCountUnlikeTheSizeLineIsRefused() throws {
        let url = try write("%%MatrixMarket matrix coordinate integer general\n3 2 3\n1 1 2\n2 2 5\n")
        XCTAssertEqual(
            refusal(url)?.errorDescription,
            "matrix.mtx states 3 entries in its size line and holds 2, so the file is cut short or was changed. Copy it again from the tool's output.")
        let more = try write("%%MatrixMarket matrix coordinate integer general\n3 2 1\n1 1 2\n2 2 5\n", named: "more.mtx")
        XCTAssertEqual(
            refusal(more)?.errorDescription,
            "more.mtx states 1 entries in its size line and holds more, so the file is cut short or was changed. Copy it again from the tool's output.")
    }

    func testAnIndexOutOfRangeIsRefused() throws {
        let url = try write("%%MatrixMarket matrix coordinate integer general\n3 2 2\n1 1 2\n4 2 5\n")
        XCTAssertEqual(
            refusal(url)?.errorDescription,
            "Line 4 of matrix.mtx names row 4 and column 2, outside the 3 rows and 2 columns of its size line.")
        let zero = try write("%%MatrixMarket matrix coordinate integer general\n3 2 1\n1 0 2\n", named: "zero.mtx")
        XCTAssertEqual(
            refusal(zero)?.errorDescription,
            "Line 3 of zero.mtx names row 1 and column 0, outside the 3 rows and 2 columns of its size line.")
    }

    func testAShortGzipIsRefusedInWords() throws {
        let whole = try Data(contentsOf: Self.cellRangerFiltered.appendingPathComponent("matrix.mtx.gz"))
        let url = root.appendingPathComponent("matrix.mtx.gz")
        try whole.prefix(whole.count / 2).write(to: url)
        let words = try XCTUnwrap(refusal(url)?.errorDescription)
        XCTAssertTrue(
            words.hasPrefix("matrix.mtx.gz ends before its gzip stream does, so the file is cut short. Copy it again from the tool's output. gzip said: "),
            words)
    }

    func testALastLineWithoutANewlineIsRead() throws {
        let url = try write("%%MatrixMarket matrix coordinate integer general\n%comment\n3 2 2\n1 1 2\n3 2 7")
        let read = try readAll(url, capacity: 1)
        XCTAssertEqual(read.entries, 2)
        XCTAssertEqual(read.sum, 9)
    }

    func testAFileWithNoHeaderIsRefused() throws {
        let url = try write("1 1 1\n")
        XCTAssertEqual(
            refusal(url)?.errorDescription,
            "matrix.mtx does not start with the header %%MatrixMarket matrix coordinate integer general, so it is no matrix LGE reads.")
    }
}
