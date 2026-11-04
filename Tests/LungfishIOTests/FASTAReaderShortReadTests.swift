// FASTAReaderShortReadTests.swift - A FASTA file that no longer holds what its index says (FASTA-READER-SHORT-READ)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO

/// A read that finds fewer bases than the index promises throws `FASTAError.fileDisagreesWithIndex`
/// instead of returning the short text (BIO-FASTA-REACH). A read that finds all its bases still
/// succeeds when the window ran on into the next record's header or past the end of the file.
final class FASTAReaderShortReadTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = try TestTempDirectory.make(prefix: "FASTAReaderShortReadTests")
    }

    override func tearDown() async throws {
        if let tempDirectory { TestTempDirectory.cleanup(tempDirectory) }
    }

    // MARK: - Fixtures

    /// Writes `fasta` and its `.fai` side by side. The index lines are `name length offset lineBases lineWidth`.
    private func writePlain(fasta: String, fai: String, name: String = "ref.fa") throws -> (fasta: URL, fai: URL) {
        let fastaURL = tempDirectory.appendingPathComponent(name)
        let faiURL = tempDirectory.appendingPathComponent("\(name).fai")
        try Data(fasta.utf8).write(to: fastaURL)
        try fai.write(to: faiURL, atomically: true, encoding: .utf8)
        return (fastaURL, faiURL)
    }

    /// Writes `fasta` as one BGZF block, the empty end block, a `.fai` and the `.gzi` bgzip leaves for a one-block file
    /// (eight zero bytes, since a `.gzi` lists only the blocks after the first).
    private func writeBgzip(fasta: String, fai: String) throws -> (fasta: URL, fai: URL, gzi: URL) {
        let fastaURL = tempDirectory.appendingPathComponent("ref.fa.gz")
        let faiURL = tempDirectory.appendingPathComponent("ref.fa.gz.fai")
        let gziURL = tempDirectory.appendingPathComponent("ref.fa.gz.gzi")
        try bgzf(Data(fasta.utf8)).write(to: fastaURL)
        try fai.write(to: faiURL, atomically: true, encoding: .utf8)
        try Data(count: 8).write(to: gziURL)
        return (fastaURL, faiURL, gziURL)
    }

    /// One BGZF block holding `payload`, then the empty block bgzip ends every file with.
    private func bgzf(_ payload: Data) throws -> Data {
        let deflated = try (payload as NSData).compressed(using: .zlib) as Data
        var block = Data([0x1f, 0x8b, 0x08, 0x04, 0, 0, 0, 0, 0, 0xff, 6, 0, 0x42, 0x43, 2, 0])
        appendLittleEndian(UInt16(18 + deflated.count + 8 - 1), to: &block)
        block.append(deflated)
        appendLittleEndian(crc32(payload), to: &block)
        appendLittleEndian(UInt32(payload.count), to: &block)
        block.append(Data([0x1f, 0x8b, 0x08, 0x04, 0, 0, 0, 0, 0, 0xff, 6, 0, 0x42, 0x43, 2, 0, 0x1b, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        return block
    }

    private func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    /// Runs `read` and expects `fileDisagreesWithIndex` for `region` with `basesRead` bases found.
    private func expectDisagreement(
        _ region: GenomicRegion,
        basesRead expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
        from read: () async throws -> String
    ) async {
        do {
            let bases = try await read()
            XCTFail("A file that holds \(expected) of \(region.length) bases must throw, and the read returned \(bases.count) bases", file: file, line: line)
        } catch {
            guard case FASTAError.fileDisagreesWithIndex(let thrownRegion, let basesRead) = error else {
                return XCTFail("Expected fileDisagreesWithIndex, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(thrownRegion.chromosome, region.chromosome, file: file, line: line)
            XCTAssertEqual(thrownRegion.start, region.start, file: file, line: line)
            XCTAssertEqual(thrownRegion.end, region.end, file: file, line: line)
            XCTAssertEqual(basesRead, expected, file: file, line: line)
        }
    }

    // MARK: - Red first: a read that comes back short throws

    /// `r` is indexed with 20 bases and the file holds 10. The read used to return those 10 with no word.
    func testPlainFetchThrowsWhenFileIsShorterThanIndex() async throws {
        let files = try writePlain(fasta: ">r\nACGTACGTAC\n", fai: "r\t20\t3\t10\t11\n")
        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)
        let region = GenomicRegion(chromosome: "r", start: 0, end: 20)

        await expectDisagreement(region, basesRead: 10) { try await reader.fetch(region: region) }
        await expectDisagreement(region, basesRead: 10) { try reader.fetchSync(region: region) }
    }

    /// `a` is indexed with 10 bases and the file holds 5 before the next record. The window ran on into the
    /// header of `b` and the read used to return `AAAAA>bCCC`.
    func testPlainFetchThrowsWhenWindowRunsIntoAHeader() async throws {
        let files = try writePlain(fasta: ">a\nAAAAA\n>b\nCCCCCCCCCCCC\n", fai: "a\t10\t3\t10\t11\n")
        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)
        let region = GenomicRegion(chromosome: "a", start: 0, end: 10)

        await expectDisagreement(region, basesRead: 5) { try await reader.fetch(region: region) }
        await expectDisagreement(region, basesRead: 5) { try reader.fetchSync(region: region) }
    }

    /// A file of zero bytes under an index that lists 20 bases used to give an empty string.
    func testPlainFetchThrowsOnEmptyFile() async throws {
        let files = try writePlain(fasta: "", fai: "r\t20\t3\t10\t11\n")
        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)
        let region = GenomicRegion(chromosome: "r", start: 0, end: 20)

        await expectDisagreement(region, basesRead: 0) { try await reader.fetch(region: region) }
        await expectDisagreement(region, basesRead: 0) { try reader.fetchSync(region: region) }
    }

    /// A one-block bgzip file replaced by a shorter one keeps its old `.fai` and its old `.gzi` with no entries.
    /// Both bgzip readers used to return the 10 bases the file holds.
    func testBgzipFetchThrowsWhenOneBlockFileIsShorterThanIndex() async throws {
        let files = try writeBgzip(fasta: ">r\nACGTACGTAC\n", fai: "r\t20\t3\t10\t11\n")
        let region = GenomicRegion(chromosome: "r", start: 0, end: 20)
        let reader = try await BgzipIndexedFASTAReader(url: files.fasta, faiURL: files.fai, gziURL: files.gzi)
        let syncReader = try SyncBgzipFASTAReader(url: files.fasta, faiURL: files.fai, gziURL: files.gzi)

        await expectDisagreement(region, basesRead: 10) { try await reader.fetch(region: region) }
        await expectDisagreement(region, basesRead: 10) { try syncReader.fetchSync(region: region) }
    }

    /// The same window check holds when the whole record is in the file and the next header follows it.
    func testBgzipFetchThrowsWhenWindowRunsIntoAHeader() async throws {
        let files = try writeBgzip(fasta: ">a\nAAAAA\n>b\nCCCCCCCCCCCC\n", fai: "a\t10\t3\t10\t11\n")
        let region = GenomicRegion(chromosome: "a", start: 0, end: 10)
        let reader = try await BgzipIndexedFASTAReader(url: files.fasta, faiURL: files.fai, gziURL: files.gzi)
        let syncReader = try SyncBgzipFASTAReader(url: files.fasta, faiURL: files.fai, gziURL: files.gzi)

        await expectDisagreement(region, basesRead: 5) { try await reader.fetch(region: region) }
        await expectDisagreement(region, basesRead: 5) { try syncReader.fetchSync(region: region) }
    }

    // MARK: - The words a person reads

    func testDisagreementWordsNameTheRecordTheCountsAndTheNextStep() {
        let region = GenomicRegion(chromosome: "MN908947", start: 0, end: 29_903)
        let words = FASTAError.fileDisagreesWithIndex(region, basesRead: 20_000).errorDescription ?? ""

        XCTAssertTrue(words.contains("does not match its index"), words)
        XCTAssertTrue(words.contains("nothing was read"), words)
        XCTAssertTrue(words.contains("MN908947 should have 29903 bases at 1-29903"), words)
        XCTAssertTrue(words.contains("the file gave 20000"), words)
        XCTAssertTrue(words.contains("Import the original FASTA again"), words)
    }

    // MARK: - Green controls: a good read is never refused

    /// The window of the first record holds the header of the second, and the read is still whole.
    func testTwoRecordFileReadsFirstRecordWhole() async throws {
        let files = try writePlain(fasta: ">a\nAAAAA\n>b\nCCCCC\n", fai: "a\t5\t3\t5\t6\nb\t5\t12\t5\t6\n")
        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)
        let first = GenomicRegion(chromosome: "a", start: 0, end: 5)
        let second = GenomicRegion(chromosome: "b", start: 0, end: 5)

        let firstAsync = try await reader.fetch(region: first)
        let secondAsync = try await reader.fetch(region: second)
        XCTAssertEqual(firstAsync, "AAAAA")
        XCTAssertEqual(secondAsync, "CCCCC")
        XCTAssertEqual(try reader.fetchSync(region: first), "AAAAA")
        XCTAssertEqual(try reader.fetchSync(region: second), "CCCCC")
    }

    func testLastLineWithNoFinalNewlineReads() async throws {
        let files = try writePlain(fasta: ">r\nACGTACGTAC\nACGTA", fai: "r\t15\t3\t10\t11\n")
        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)
        let region = GenomicRegion(chromosome: "r", start: 0, end: 15)

        let fetched = try await reader.fetch(region: region)
        XCTAssertEqual(fetched, "ACGTACGTACACGTA")
        XCTAssertEqual(try reader.fetchSync(region: region), "ACGTACGTACACGTA")
    }

    func testCRLFRecordReadsWhole() async throws {
        let files = try writePlain(fasta: ">r\r\nACGTAC\r\nGGTTAA\r\n", fai: "r\t12\t4\t6\t8\n")
        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)
        let whole = GenomicRegion(chromosome: "r", start: 0, end: 12)
        let acrossTheBreak = GenomicRegion(chromosome: "r", start: 4, end: 10)

        let fetchedWhole = try await reader.fetch(region: whole)
        let fetchedAcross = try await reader.fetch(region: acrossTheBreak)
        XCTAssertEqual(fetchedWhole, "ACGTACGGTTAA")
        XCTAssertEqual(fetchedAcross, "ACGGTT")
        XCTAssertEqual(try reader.fetchSync(region: whole), "ACGTACGGTTAA")
        XCTAssertEqual(try reader.fetchSync(region: acrossTheBreak), "ACGGTT")
    }

    func testEmptyRegionReturnsEmpty() async throws {
        let files = try writePlain(fasta: ">r\nACGTACGTAC\n", fai: "r\t10\t3\t10\t11\n")
        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)
        let empty = GenomicRegion(chromosome: "r", start: 4, end: 4)

        let fetched = try await reader.fetch(region: empty)
        XCTAssertEqual(fetched, "")
        XCTAssertEqual(try reader.fetchSync(region: empty), "")
    }

    /// A one-block bgzip file whose index and file agree reads whole, with the empty end block after it.
    func testBgzipFetchReadsWholeWhenFileMatchesIndex() async throws {
        let files = try writeBgzip(fasta: ">r\nACGTACGTAC\nACGTA\n", fai: "r\t15\t3\t10\t11\n")
        let region = GenomicRegion(chromosome: "r", start: 0, end: 15)
        let reader = try await BgzipIndexedFASTAReader(url: files.fasta, faiURL: files.fai, gziURL: files.gzi)
        let syncReader = try SyncBgzipFASTAReader(url: files.fasta, faiURL: files.fai, gziURL: files.gzi)

        let fetched = try await reader.fetch(region: region)
        XCTAssertEqual(fetched, "ACGTACGTACACGTA")
        XCTAssertEqual(try syncReader.fetchSync(region: region), "ACGTACGTACACGTA")
    }
}
