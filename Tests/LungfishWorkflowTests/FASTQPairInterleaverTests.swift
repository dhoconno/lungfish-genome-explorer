// FASTQPairInterleaverTests.swift - Unit tests for the tool-free R1/R2 interleaver
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class FASTQPairInterleaverTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQPairInterleaverTests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func write(_ text: String, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Compresses `url` with the system gzip so the reader's gzip path is
    /// exercised against a real stream, and returns the `.gz` URL.
    private func gzipped(_ url: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", "-f", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip should compress the fixture")
        return url.appendingPathExtension("gz")
    }

    private func interleave(_ r1: URL, _ r2: URL) throws -> (counts: FASTQPairInterleaver.Counts, bytes: Data) {
        let output = root.appendingPathComponent("interleaved-\(UUID().uuidString).fastq")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: output.path))
        let counts: FASTQPairInterleaver.Counts
        do {
            counts = try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle)
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return (counts, try Data(contentsOf: output))
    }

    // Records deliberately carry a repeated name on the `+` line, a trailing
    // carriage return, and a `@` inside a quality string: every byte must
    // survive untouched.
    private let r1Text = """
        @read1/1 extra words\r
        ACGTACGTAC\r
        +read1/1\r
        II@IIIIIII\r
        @read2/1
        GGGGCCCCAA
        +
        !!!!!!!!!!

        """

    private let r2Text = """
        @read1/2
        TTTTTTTTTT
        +
        #########+
        @read2/2
        CCCCCCCCCC
        +
        FFFFFFFFFF

        """

    private let expectedInterleaved = """
        @read1/1 extra words\r
        ACGTACGTAC\r
        +read1/1\r
        II@IIIIIII\r
        @read1/2
        TTTTTTTTTT
        +
        #########+
        @read2/1
        GGGGCCCCAA
        +
        !!!!!!!!!!
        @read2/2
        CCCCCCCCCC
        +
        FFFFFFFFFF

        """

    // MARK: - Tests

    func testInterleavesEachR1RecordDirectlyBeforeItsMateByteForByte() throws {
        let r1 = try write(r1Text, name: "r1.fastq")
        let r2 = try write(r2Text, name: "r2.fastq")

        let result = try interleave(r1, r2)

        XCTAssertEqual(result.counts, FASTQPairInterleaver.Counts(r1Records: 2, r2Records: 2, writtenRecords: 4))
        XCTAssertEqual(result.bytes, Data(expectedInterleaved.utf8))
    }

    func testMissingTrailingNewlineIsNormalisedWithoutLosingTheLastRecord() throws {
        let r1 = try write(String(r1Text.dropLast()), name: "r1.fastq")
        let r2 = try write(String(r2Text.dropLast()), name: "r2.fastq")

        let result = try interleave(r1, r2)

        XCTAssertEqual(result.counts.writtenRecords, 4)
        XCTAssertEqual(result.bytes, Data(expectedInterleaved.utf8))
    }

    func testGzipInputsProduceTheSameOutputAsPlainInputs() throws {
        let r1 = try write(r1Text, name: "r1.fastq")
        let r2 = try write(r2Text, name: "r2.fastq")
        let r1gz = try gzipped(r1)
        let r2gz = try gzipped(r2)

        let plain = try interleave(r1, r2)
        let mixed = try interleave(r1gz, r2)
        let compressed = try interleave(r1gz, r2gz)

        XCTAssertEqual(mixed.bytes, plain.bytes)
        XCTAssertEqual(compressed.bytes, plain.bytes)
        XCTAssertEqual(compressed.counts, plain.counts)
    }

    func testMismatchedMateCountsThrowAndNameBothCounts() throws {
        let r1 = try write(r1Text, name: "r1.fastq")
        let r2Short = try write(String(r2Text.split(separator: "\n").prefix(4).joined(separator: "\n")) + "\n", name: "r2.fastq")

        XCTAssertThrowsError(try interleave(r1, r2Short)) { error in
            guard case FASTQPairInterleaver.InterleaveError.mateCountMismatch(let r1File, let r1Records, let r2File, let r2Records) = error else {
                return XCTFail("Expected mateCountMismatch, got \(error)")
            }
            XCTAssertEqual(r1File, "r1.fastq")
            XCTAssertEqual(r1Records, 2)
            XCTAssertEqual(r2File, "r2.fastq")
            XCTAssertEqual(r2Records, 1)
        }

        // The longer file may be either mate.
        XCTAssertThrowsError(try interleave(r2Short, r1)) { error in
            guard case FASTQPairInterleaver.InterleaveError.mateCountMismatch = error else {
                return XCTFail("Expected mateCountMismatch, got \(error)")
            }
        }
    }

    func testMalformedRecordThrows() throws {
        let r1 = try write("@ok\nACGT\n+\nIIII\nnot-a-header\nACGT\n+\nIIII\n", name: "r1.fastq")
        let r2 = try write(r2Text, name: "r2.fastq")

        XCTAssertThrowsError(try interleave(r1, r2)) { error in
            guard case FASTQPairInterleaver.InterleaveError.malformedRecord(let file, let recordNumber, _) = error else {
                return XCTFail("Expected malformedRecord, got \(error)")
            }
            XCTAssertEqual(file, "r1.fastq")
            XCTAssertEqual(recordNumber, 2)
        }

        let truncated = try write("@ok\nACGT\n+\n", name: "truncated.fastq")
        XCTAssertThrowsError(try interleave(truncated, r2)) { error in
            guard case FASTQPairInterleaver.InterleaveError.malformedRecord = error else {
                return XCTFail("Expected malformedRecord, got \(error)")
            }
        }
    }

    func testCountRecordsHandlesPlainAndGzipFiles() throws {
        let plain = try write(r1Text, name: "reads.fastq")
        let compressed = try gzipped(plain)
        let noTrailingNewline = try write(String(r2Text.dropLast()), name: "no-newline.fastq")
        let empty = try write("", name: "empty.fastq")

        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: plain), 2)
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: compressed), 2)
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: noTrailingNewline), 2)
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: empty), 0)
    }

    func testCountRecordsRejectsATruncatedFile() throws {
        let truncated = try write("@a\nACGT\n+\nIIII\n@b\nACGT\n", name: "truncated.fastq")

        XCTAssertThrowsError(try FASTQPairInterleaver.countRecords(in: truncated)) { error in
            guard case FASTQPairInterleaver.InterleaveError.malformedRecord = error else {
                return XCTFail("Expected malformedRecord, got \(error)")
            }
        }
    }

    // MARK: - Deinterleave

    private func deinterleave(_ url: URL) throws -> (counts: FASTQPairInterleaver.Counts, r1: Data, r2: Data) {
        let out1 = root.appendingPathComponent("split-r1-\(UUID().uuidString).fastq")
        let out2 = root.appendingPathComponent("split-r2-\(UUID().uuidString).fastq")
        FileManager.default.createFile(atPath: out1.path, contents: nil)
        FileManager.default.createFile(atPath: out2.path, contents: nil)
        let h1 = try XCTUnwrap(FileHandle(forWritingAtPath: out1.path))
        let h2 = try XCTUnwrap(FileHandle(forWritingAtPath: out2.path))
        defer {
            try? h1.close()
            try? h2.close()
        }
        let counts = try FASTQPairInterleaver.deinterleave(interleaved: url, r1: h1, r2: h2)
        try h1.close()
        try h2.close()
        return (counts, try Data(contentsOf: out1), try Data(contentsOf: out2))
    }

    func testDeinterleaveRestoresTheOriginalMateFilesByteForByte() throws {
        let interleaved = try write(expectedInterleaved, name: "interleaved.fastq")

        let plain = try deinterleave(interleaved)
        XCTAssertEqual(plain.counts, FASTQPairInterleaver.Counts(r1Records: 2, r2Records: 2, writtenRecords: 4))
        XCTAssertEqual(plain.r1, Data(r1Text.utf8))
        XCTAssertEqual(plain.r2, Data(r2Text.utf8))

        let compressed = try deinterleave(try gzipped(interleaved))
        XCTAssertEqual(compressed.r1, plain.r1)
        XCTAssertEqual(compressed.r2, plain.r2)
    }

    func testDeinterleaveRejectsAnOddRecordCount() throws {
        let odd = try write(expectedInterleaved + "@orphan/1\nACGT\n+\nIIII\n", name: "odd.fastq")

        XCTAssertThrowsError(try deinterleave(odd)) { error in
            guard case FASTQPairInterleaver.InterleaveError.mateCountMismatch(_, let r1Records, _, let r2Records) = error else {
                return XCTFail("Expected mateCountMismatch, got \(error)")
            }
            XCTAssertEqual(r1Records, 3)
            XCTAssertEqual(r2Records, 2)
        }
    }

    func testUnreadableInputThrows() {
        let missing = root.appendingPathComponent("missing.fastq")
        XCTAssertThrowsError(try FASTQPairInterleaver.countRecords(in: missing)) { error in
            guard case FASTQPairInterleaver.InterleaveError.unreadableInput = error else {
                return XCTFail("Expected unreadableInput, got \(error)")
            }
        }
    }
}
