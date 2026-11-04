// FASTAIndexZeroLineBasesTests.swift - A .fai line with no bases per line must not trap a read (FASTAREAD review, backlog item 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO

/// `FASTAIndex.byteOffset(for:in:)` divides by `entry.lineBases`, so a `.fai` line with 0 in its fourth column used to
/// trap on any read of that record, an empty read included. A record with bases and no line length is now refused when
/// the index is parsed, and a record of length 0 reads as an empty string before the division. A line that a good tool
/// writes still opens. samtools leaves an empty record out of its index, and the assembly bundle's fallback index
/// writes `length 0, lineBases 0` for an empty first contig.
final class FASTAIndexZeroLineBasesTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = try TestTempDirectory.make(prefix: "FASTAIndexZeroLineBasesTests")
    }

    override func tearDown() async throws {
        if let tempDirectory { TestTempDirectory.cleanup(tempDirectory) }
    }

    // MARK: - Fixtures

    /// A FASTA whose second record is empty, and the index lines for it as the assembly fallback writes them.
    /// `empty` starts at byte 15, where the header of `c` follows its own header.
    private let emptyRecordFASTA = ">a\nACGT\n>empty\n>c\nGG\n"
    private let emptyRecordIndex = "a\t4\t3\t4\t5\nempty\t0\t15\t0\t0\nc\t2\t18\t2\t3\n"

    /// Writes `fasta` and its `.fai` side by side. The index lines are `name length offset lineBases lineWidth`.
    private func writePlain(fasta: String, fai: String) throws -> (fasta: URL, fai: URL) {
        let fastaURL = tempDirectory.appendingPathComponent("ref.fa")
        let faiURL = tempDirectory.appendingPathComponent("ref.fa.fai")
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

    /// Runs `open` and expects the refusal in words: the line, the record named in quotes, and the next step.
    private func expectRefusal(
        naming record: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        from open: () async throws -> Void
    ) async {
        do {
            try await open()
            XCTFail("An index line with bases and no bases per line must be refused when the index is opened", file: file, line: line)
        } catch {
            guard case FASTAError.invalidIndex(let words) = error else {
                return XCTFail("Expected invalidIndex, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(words.contains("Line 2"), "The words must name the line. Got \(words)", file: file, line: line)
            XCTAssertTrue(words.contains("'\(record)'"), "The words must name the record. Got \(words)", file: file, line: line)
            XCTAssertTrue(words.contains("faidx"), "The words must say how to index again. Got \(words)", file: file, line: line)
            XCTAssertTrue(words.contains("import the original FASTA"), "The words must say what else to do. Got \(words)", file: file, line: line)
        }
    }

    // MARK: - Red first: a record with bases and no line length is refused when the index is parsed

    /// `r` has 20 bases and 0 bases per line. Any read of it divided by zero.
    func testIndexRefusesZeroBasesPerLineForARecordWithBases() async throws {
        let files = try writePlain(fasta: ">a\nACGT\n>r\nACGTACGTAC\nACGTACGTAC\n", fai: "a\t4\t3\t4\t5\nr\t20\t15\t0\t11\n")

        await expectRefusal(naming: "r") { _ = try FASTAIndex(url: files.fai) }
    }

    func testIndexRefusesNegativeBasesPerLineForARecordWithBases() async throws {
        let files = try writePlain(fasta: ">a\nACGT\n>r\nACGTACGTAC\n", fai: "a\t4\t3\t4\t5\nr\t10\t15\t-10\t11\n")

        await expectRefusal(naming: "r") { _ = try FASTAIndex(url: files.fai) }
    }

    /// The readers open their index through the same parse, so none of them opens a file it could not read.
    func testEveryReaderRefusesTheIndexWhenItOpens() async throws {
        let plain = try writePlain(fasta: ">a\nACGT\n>r\nACGTACGTAC\n", fai: "a\t4\t3\t4\t5\nr\t10\t15\t0\t11\n")
        let bgzip = try writeBgzip(fasta: ">a\nACGT\n>r\nACGTACGTAC\n", fai: "a\t4\t3\t4\t5\nr\t10\t15\t0\t11\n")

        await expectRefusal(naming: "r") { _ = try IndexedFASTAReader(url: plain.fasta, indexURL: plain.fai) }
        await expectRefusal(naming: "r") { _ = try await BgzipIndexedFASTAReader(url: bgzip.fasta, faiURL: bgzip.fai, gziURL: bgzip.gzi) }
        await expectRefusal(naming: "r") { _ = try SyncBgzipFASTAReader(url: bgzip.fasta, faiURL: bgzip.fai, gziURL: bgzip.gzi) }
    }

    // MARK: - Red first: a record of length 0 reads as empty before the division

    /// The index line is what the assembly bundle's fallback writes for an empty contig. The reads divided by 0.
    /// The neighbours are read first, so the failing read is the empty record alone.
    func testPlainReadsOfAnEmptyRecordReturnNothing() async throws {
        let files = try writePlain(fasta: emptyRecordFASTA, fai: emptyRecordIndex)
        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)
        let empty = GenomicRegion(chromosome: "empty", start: 0, end: 0)

        let first = try await reader.fetch(region: GenomicRegion(chromosome: "a", start: 0, end: 4))
        XCTAssertEqual(first, "ACGT")
        XCTAssertEqual(try reader.fetchSync(region: GenomicRegion(chromosome: "c", start: 0, end: 2)), "GG")

        let asyncRead = try await reader.fetch(region: empty)
        XCTAssertEqual(asyncRead, "")
        XCTAssertEqual(try reader.fetchSync(region: empty), "")
    }

    func testBgzipReadsOfAnEmptyRecordReturnNothing() async throws {
        let files = try writeBgzip(fasta: emptyRecordFASTA, fai: emptyRecordIndex)
        let reader = try await BgzipIndexedFASTAReader(url: files.fasta, faiURL: files.fai, gziURL: files.gzi)
        let syncReader = try SyncBgzipFASTAReader(url: files.fasta, faiURL: files.fai, gziURL: files.gzi)
        let empty = GenomicRegion(chromosome: "empty", start: 0, end: 0)

        let first = try await reader.fetch(region: GenomicRegion(chromosome: "a", start: 0, end: 4))
        XCTAssertEqual(first, "ACGT")
        XCTAssertEqual(try syncReader.fetchSync(region: GenomicRegion(chromosome: "c", start: 0, end: 2)), "GG")

        let asyncRead = try await reader.fetch(region: empty)
        XCTAssertEqual(asyncRead, "")
        XCTAssertEqual(try syncReader.fetchSync(region: empty), "")
    }

    // MARK: - Controls: an index that a good tool writes still opens

    /// Control. A line of length 0 with 0 bases per line is not refused, since the assembly fallback writes one.
    func testIndexWithAnEmptyRecordLineStillOpens() throws {
        let files = try writePlain(fasta: emptyRecordFASTA, fai: emptyRecordIndex)

        let index = try FASTAIndex(url: files.fai)

        XCTAssertEqual(index.sequenceNames, ["a", "empty", "c"])
        XCTAssertEqual(index.entry(for: "empty")?.length, 0)
        XCTAssertEqual(index.entry(for: "a")?.lineBases, 4)
        XCTAssertEqual(index.entry(for: "c")?.lineBases, 2)
    }

    /// Control. One base per line is the narrowest layout that has bases, and it opens and reads.
    func testIndexWithOneBasePerLineStillOpensAndReads() throws {
        let files = try writePlain(fasta: ">r\nA\nC\nG\nT\n", fai: "r\t4\t3\t1\t2\n")

        let reader = try IndexedFASTAReader(url: files.fasta, indexURL: files.fai)

        XCTAssertEqual(try reader.fetchSync(region: GenomicRegion(chromosome: "r", start: 1, end: 4)), "CGT")
    }

    /// Control. The index Lungfish writes for a FASTA with empty records leaves them out, opens again and reads.
    func testIndexLungfishWritesForEmptyRecordsOpensAndReads() throws {
        let fastaURL = tempDirectory.appendingPathComponent("lungfish.fa")
        try Data(">e1\n>a\nACGT\n>e2\n>c\nGG\n>e3\n".utf8).write(to: fastaURL)
        try FASTAIndexBuilder.buildAndWrite(for: fastaURL)

        let index = try FASTAIndex(url: fastaURL.appendingPathExtension("fai"))
        let reader = try IndexedFASTAReader(url: fastaURL)

        XCTAssertEqual(index.sequenceNames, ["a", "c"])
        for name in index.sequenceNames {
            XCTAssertGreaterThan(index.entry(for: name)?.lineBases ?? 0, 0, "\(name) must have bases per line")
        }
        XCTAssertEqual(try reader.fetchSync(region: GenomicRegion(chromosome: "a", start: 0, end: 4)), "ACGT")
        XCTAssertEqual(try reader.fetchSync(region: GenomicRegion(chromosome: "c", start: 0, end: 2)), "GG")
    }
}
