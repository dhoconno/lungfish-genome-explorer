// GzipReaderSitePinTests.swift - Pins of the gzip, gzcat and wc readers, from before Phase 2.13 lane 13.07
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// The sites that read a decompressor's output: `DemultiplexingPipeline.countReadsInFASTQ` (gzcat or cat into
/// wc) and `FASTQRawLineReader` (gzip -dc). Each pin holds the bytes or counts handed over for a plain and a gzip
/// input and the failure words, and it passes unchanged before and after the sites move onto `ToolProcess`.
final class GzipReaderSitePinTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "gzip-reader-pins")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(scratch)
    }

    private static func fastq(records: Int) -> Data {
        let sequence = String(repeating: "ACGT", count: 10)
        let quality = String(repeating: "I", count: 40)
        var text = String()
        text.reserveCapacity(records * 100)
        for index in 0..<records {
            text += "@read\(index)\n\(sequence)\n+\n\(quality)\n"
        }
        return Data(text.utf8)
    }

    // MARK: - DemultiplexingPipeline.swift countReadsInFASTQ

    func testCountReadsInFASTQCountsPlainAndGzipFilesAndAnswersZeroWhenGzcatOrCatFails() throws {
        let pipeline = DemultiplexingPipeline()
        let raw = Self.fastq(records: 250)
        let plain = scratch.appendingPathComponent("reads.fastq")
        let gz = scratch.appendingPathComponent("reads.fastq.gz")
        let upper = scratch.appendingPathComponent("upper.fastq.GZ")
        try raw.write(to: plain)
        try GzipPin.gzip(["-n", "-c"], stdin: raw).write(to: gz)
        try FileManager.default.copyItem(at: gz, to: upper)
        XCTAssertEqual(pipeline.countReadsInFASTQ(url: plain), 250)
        XCTAssertEqual(pipeline.countReadsInFASTQ(url: gz), 250)
        XCTAssertEqual(pipeline.countReadsInFASTQ(url: upper), 250, "the extension is compared in lower case")

        let ragged = scratch.appendingPathComponent("ragged.fastq")
        try Data("@a\nAC\n+\nII\n@b\nGT\n".utf8).write(to: ragged)
        XCTAssertEqual(pipeline.countReadsInFASTQ(url: ragged), 1, "six lines are one whole record")

        let empty = scratch.appendingPathComponent("empty.fastq")
        try Data().write(to: empty)
        XCTAssertEqual(pipeline.countReadsInFASTQ(url: empty), 0)
        XCTAssertEqual(pipeline.countReadsInFASTQ(url: scratch.appendingPathComponent("missing.fastq")), 0)
        XCTAssertEqual(pipeline.countReadsInFASTQ(url: scratch.appendingPathComponent("missing.fastq.gz")), 0)
        let fake = scratch.appendingPathComponent("fake.fastq.gz")
        try raw.write(to: fake)
        XCTAssertEqual(pipeline.countReadsInFASTQ(url: fake), 0, "gzcat refuses a file that is not gzip")
    }

    // MARK: - FASTQPairInterleaver.swift FASTQRawLineReader

    func testRawLineReaderHandsOverTheSameBytesForPlainAndGzipInputs() throws {
        let raw = Self.fastq(records: 30_000)
        XCTAssertGreaterThan(raw.count, 2 * 1_048_576, "more than two of the reader's chunks")
        let plain = scratch.appendingPathComponent("big.fastq")
        let gz = scratch.appendingPathComponent("big.fastq.gz")
        try raw.write(to: plain)
        try GzipPin.gzip(["-n", "-c"], stdin: raw).write(to: gz)
        let digest = GzipPin.sha256Hex(raw)

        for url in [plain, gz] {
            let chunked = try FASTQRawLineReader(url: url)
            var chunks = Data()
            while let chunk = try chunked.readChunk() {
                chunks.append(contentsOf: chunk)
            }
            chunked.close()
            XCTAssertEqual(GzipPin.sha256Hex(chunks), digest, "readChunk of \(url.lastPathComponent)")

            let lined = try FASTQRawLineReader(url: url)
            var lines = Data()
            var count = 0
            while let line = try lined.nextLine() {
                lines.append(contentsOf: line)
                lines.append(0x0A)
                count += 1
            }
            lined.close()
            XCTAssertEqual(count, 120_000, "lines of \(url.lastPathComponent)")
            XCTAssertEqual(GzipPin.sha256Hex(lines), digest, "nextLine of \(url.lastPathComponent)")
        }
    }

    func testRawLineReaderFailureWordsForACorruptGzipAndAMissingFile() throws {
        let sample = String(repeating: "@r1\nACGTACGTAC\n+\nIIIIIIIIII\n@r2\nTTGCAACGGT\n+\nHHHHHHHHHH\n", count: 50)
        let good = try GzipPin.gzip(["-n", "-c"], stdin: Data(sample.utf8))
        let corrupt = scratch.appendingPathComponent("corrupt.fastq.gz")
        try (good.prefix(12) + Data(repeating: 0xFF, count: 6) + good.dropFirst(18)).write(to: corrupt)

        let reader = try FASTQRawLineReader(url: corrupt)
        XCTAssertThrowsError(try reader.nextLine()) { error in
            guard case FASTQPairInterleaver.InterleaveError.unreadableInput(let file, let reason) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(file, "corrupt.fastq.gz")
            XCTAssertEqual(reason, "gzip decompression failed (exit 1)")
        }
        reader.close()

        XCTAssertThrowsError(try FASTQRawLineReader(url: scratch.appendingPathComponent("missing.fastq.gz"))) { error in
            guard case FASTQPairInterleaver.InterleaveError.unreadableInput(let file, let reason) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(file, "missing.fastq.gz")
            XCTAssertEqual(reason, "file not found or not readable")
        }
    }

    func testClosingTheRawLineReaderEarlyEndsGzipBeforeCloseReturns() throws {
        let gz = scratch.appendingPathComponent("zeros.fastq.gz")
        let zeros = Data(repeating: UInt8(ascii: "A"), count: 40 * 1_048_576)
        try GzipPin.gzip(["-n", "-c"], stdin: zeros).write(to: gz)

        let reader = try FASTQRawLineReader(url: gz)
        let first = try XCTUnwrap(try reader.readChunk())
        XCTAssertFalse(first.isEmpty)
        let started = Date()
        reader.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        XCTAssertFalse(try GzipPin.processCommands().contains(gz.path), "gzip -dc of the file is gone")
        reader.close()
    }
}
