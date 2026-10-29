// UnflaggedRecordFASTQWriterTests.swift - SAM text to FASTQ for records with neither mate flag
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane FASTQ-SAME-NAME, ruling R1 of the IDPINS review. The writer behind `convertBAMToSingleFASTQ` turns
// each SAM record that carries neither READ1 nor READ2 into one FASTQ record. These tests hold it to what `samtools
// fastq` 1.24 gives for a record it handles right (the expected strings below, the reverse-strand IUPAC line and the
// quality of a record with none, are what that tool wrote for the same records) and to the rules the ruling adds: no
// record dropped for sharing a name, a sequence or a quality, no `/1` or `/2`, no record with an empty sequence. They
// need no tool, so they run in the unit tier. The BAM-level cases with the real samtools are in
// `BAMToFASTQConverterSameNameConformanceTests`.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class UnflaggedRecordFASTQWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "unflagged-fastq-writer")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    // MARK: - Records

    func testForwardRecordIsWrittenAsItIsWithNoSuffixAndNoTags() throws {
        let line = sam("SRR35517702.12", 0, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ", tags: ["NM:i:0", "AS:i:50"])
        let result = try write(line + "\n")
        XCTAssertEqual(result.fastq, "@SRR35517702.12\nAAAACCCCGG\n+\nABCDEFGHIJ\n")
        XCTAssertEqual(result.records, 1)
    }

    func testReverseStrandRecordIsRestoredWithItsIUPACLetters() throws {
        let result = try write(sam("q", 16, seq: "ACGTRYKMBVDHSWN", qual: "0123456789ABCDE") + "\n")
        XCTAssertEqual(result.fastq, "@q\nNWSDHBVKMRYACGT\n+\nEDCBA9876543210\n")
    }

    func testRecordWithNoSequenceIsLeftOutAndRecordWithNoQualitiesGetsB() throws {
        let text = [
            sam("star", 0, seq: "*", qual: "*"),
            sam("noqual", 0, seq: "ACGTACGTAC", qual: "*"),
            sam("noqual-reverse", 16, seq: "AACCGGTTAC", qual: "*"),
            sam("ok", 0, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
        ].joined(separator: "\n") + "\n"
        let result = try write(text)
        XCTAssertEqual(
            result.fastq,
            "@noqual\nACGTACGTAC\n+\nBBBBBBBBBB\n@noqual-reverse\nGTAACCGGTT\n+\nBBBBBBBBBB\n@ok\nAAAACCCCGG\n+\nABCDEFGHIJ\n"
        )
        XCTAssertEqual(result.records, 3, "the record with no sequence is not counted")
    }

    /// Two real mates of one name can restore to the same sequence and qualities (a fully overlapping pair), and the
    /// estimate counts both, so a rule keyed on the name, the sequence and the qualities would lose a real mate.
    func testRecordsOfOneNameAreAllWrittenEvenWhenTheyRestoreToTheSameRead() throws {
        let text = [
            sam("r1", 0, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
            sam("r1", 16, seq: "CCGGGGTTTT", qual: "JIHGFEDCBA"),
            sam("r2", 0, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
            sam("r2", 0, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
        ].joined(separator: "\n") + "\n"
        let result = try write(text)
        let record = "AAAACCCCGG\n+\nABCDEFGHIJ\n"
        XCTAssertEqual(result.fastq, "@r1\n\(record)@r1\n\(record)@r2\n\(record)@r2\n\(record)")
        XCTAssertEqual(result.records, 4)
    }

    func testBlankLinesAreSkippedAndAMissingFinalNewlineStillWritesTheRecord() throws {
        let first = sam("a", 0, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ")
        let second = sam("b", 0, seq: "GGGGTTTTAA", qual: "JIHGFEDCBA")
        let result = try write("\n" + first + "\n\n" + second)
        XCTAssertEqual(result.fastq, "@a\nAAAACCCCGG\n+\nABCDEFGHIJ\n@b\nGGGGTTTTAA\n+\nJIHGFEDCBA\n")
        XCTAssertEqual(try write("").fastq, "")
    }

    /// 20,000 records of 100 bases are 5 MB of SAM text, so the 1 MB reads cut lines in the middle.
    func testEveryRecordIsWrittenInOrderAcrossTheReadChunks() throws {
        let sequence = String(repeating: "AACCGGTTAC", count: 10)
        let quality = String(repeating: "ABCDEFGHIJ", count: 10)
        let restoredReverse = String(repeating: "GTAACCGGTT", count: 10)
        let restoredQuality = String(repeating: "JIHGFEDCBA", count: 10)
        let count = 20_000
        let text = (0..<count).map { index in
            sam("SRR1.\(index)", index % 2 == 0 ? 0 : 16, seq: sequence, qual: quality)
        }.joined(separator: "\n") + "\n"
        let result = try write(text)
        XCTAssertEqual(result.records, count)
        let lines = result.fastq.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, count * 4 + 1, "four lines a record and the empty piece after the last newline")
        var wrong: [String] = []
        for index in 0..<count {
            let at = index * 4
            let forward = index % 2 == 0
            let expected = ["@SRR1.\(index)", forward ? sequence : restoredReverse, "+", forward ? quality : restoredQuality]
            if Array(lines[at..<at + 4].map(String.init)) != expected { wrong.append("record \(index)") }
            if wrong.count >= 5 { break }
        }
        XCTAssertEqual(wrong, [], "records that differ from the expected restored read")
    }

    // MARK: - Lines the converter cannot read

    func testALineThatIsNotASAMRecordThrowsWords() {
        expectFailure("a\t0\tref\t100\t60\n", contains: "5 tab-separated fields")
        expectFailure(sam("r1", 0, seq: "ACGTACGTAC", qual: "IIIIIIIII") + "\n", contains: "10 bases and 9 quality values")
        expectFailure("r1\tx\tref\t100\t60\t10M\t*\t0\t0\tACGTACGTAC\tIIIIIIIIII\n", contains: "FLAG that is not a number")
    }

    // MARK: - Helpers

    private func sam(_ name: String, _ flag: Int, seq: String, qual: String, tags: [String] = []) -> String {
        ([name, String(flag), "ref", "100", "60", "10M", "*", "0", "0", seq, qual] + tags).joined(separator: "\t")
    }

    /// Writes `text` as a SAM text file and returns the FASTQ text and the record count the writer gives for it.
    private func write(_ text: String) throws -> (fastq: String, records: Int) {
        let source = root.appendingPathComponent("in-\(UUID().uuidString).sam")
        try text.write(to: source, atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent("out-\(UUID().uuidString).fastq")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        let records: Int
        do {
            records = try UnflaggedRecordFASTQWriter.writeRecords(fromSAMText: source, to: handle)
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return (try String(contentsOf: target, encoding: .utf8), records)
    }

    private func expectFailure(_ text: String, contains fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try write(text), file: file, line: line) { error in
            guard case BAMToFASTQConversionError.samtoolsFailed(let stderr) = error else {
                return XCTFail("\(error) is not a samtoolsFailed error", file: file, line: line)
            }
            XCTAssertTrue(stderr.contains(fragment), "\(stderr) does not hold \(fragment)", file: file, line: line)
        }
    }
}
