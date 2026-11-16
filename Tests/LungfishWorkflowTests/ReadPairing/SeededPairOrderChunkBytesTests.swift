// SeededPairOrderChunkBytesTests.swift - bucket files of many chunks stage the seeded order byte for byte
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row FASTP-STAGING-MEMORY (review FASTP-MEM-BIO, should-fix 1). SeededPairOrder.BucketFiles writes a bucket as LZ4
// chunks of at most 1 MiB, each appended with a POSIX write, and reads the chunks back into two buffers that every
// bucket shares. The byte tests of the order stage 500 pairs or fewer, under 1 MiB a bucket, so each bucket file holds
// one chunk and the read never meets a second. SeededPairOrderMemoryTests makes many chunks a bucket, but it writes to
// /dev/null and asserts the footprint. This test stages 6,000 pairs of two 450-base reads, about 11 MB, into real
// files. At one bucket the file holds over ten chunks, and at three or two buckets each bucket holds several. Each
// staged file must equal the source records laid out in the order of SeededPairOrder.order(count:), byte for byte.

import XCTest
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class SeededPairOrderChunkBytesTests: XCTestCase {

    private static let pairCount = 6_000
    private static let readLength = 450

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "seeded-pair-order-chunk-bytes")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The records of a plain FASTQ file as raw bytes, each its four lines with their newlines, read the way the
    /// staging reads them.
    private func records(_ url: URL) throws -> [Data] {
        let reader = try FASTQRawLineReader(url: url)
        defer { reader.close() }
        var records: [Data] = []
        var record = Data()
        var lines = 0
        while let line = try reader.nextLine() {
            record.append(contentsOf: line)
            record.append(0x0A)
            lines += 1
            if lines == 4 {
                records.append(record)
                record = Data()
                lines = 0
            }
        }
        XCTAssertEqual(lines, 0, "\(url.lastPathComponent) holds whole records")
        return records
    }

    /// The records laid end to end in the order of `order`.
    private func laidOut(_ records: [Data], in order: [Int]) -> Data {
        var data = Data()
        for index in order { data.append(records[index]) }
        return data
    }

    private func assertSameBytes(
        _ staged: Data, _ expected: Data, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard staged != expected else { return }
        let agreeing = zip(staged, expected).prefix { $0 == $1 }.count
        XCTFail(
            "\(what) staged \(staged.count) bytes where \(expected.count) were expected, and the two first differ at byte \(agreeing)",
            file: file, line: line
        )
    }

    /// Stages the pairs of two mate files with `SeededPairOrder.write` into two real files, and returns their bytes.
    private func stagePairs(r1: URL, r2: URL, buckets: Int) throws -> (r1: Data, r2: Data) {
        let out1 = root.appendingPathComponent("staged-\(buckets)_R1.fastq")
        let out2 = root.appendingPathComponent("staged-\(buckets)_R2.fastq")
        FileManager.default.createFile(atPath: out1.path, contents: nil)
        FileManager.default.createFile(atPath: out2.path, contents: nil)
        let handle1 = try FileHandle(forWritingTo: out1)
        let handle2 = try FileHandle(forWritingTo: out2)
        let scratch = root.appendingPathComponent("scratch-\(buckets)", isDirectory: true)
        let pairs: Int
        do {
            pairs = try SeededPairOrder.write(
                .separate(r1: r1, r2: r2), r1: handle1, r2: handle2, scratch: scratch, bucketCount: buckets
            )
        } catch {
            try? handle1.close()
            try? handle2.close()
            throw error
        }
        try handle1.close()
        try handle2.close()
        XCTAssertEqual(pairs, Self.pairCount, "pairs staged at \(buckets) buckets")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "the bucket files are gone at \(buckets) buckets")
        return (try Data(contentsOf: out1), try Data(contentsOf: out2))
    }

    func testChunkedBucketFilesStageTheSeededOrderByteForByte() throws {
        let r1 = root.appendingPathComponent("source_R1.fastq")
        let r2 = root.appendingPathComponent("source_R2.fastq")
        try SeededPairOrderMemoryTests.writeSyntheticPairs(
            r1: r1, r2: r2, pairs: Self.pairCount, readLength: Self.readLength
        )
        let sourceR1 = try records(r1)
        let sourceR2 = try records(r2)
        XCTAssertEqual(sourceR1.count, Self.pairCount)
        XCTAssertEqual(sourceR2.count, Self.pairCount)
        let textBytes = (sourceR1 + sourceR2).reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(textBytes, 10 << 20, "over ten chunks of the 1 MiB a bucket flushes at, when there is one bucket")

        let order = SeededPairOrder.order(count: Self.pairCount)
        let expectedR1 = laidOut(sourceR1, in: order)
        let expectedR2 = laidOut(sourceR2, in: order)
        for buckets in [1, 3] {
            let staged = try stagePairs(r1: r1, r2: r2, buckets: buckets)
            assertSameBytes(staged.r1, expectedR1, "R1 of write at \(buckets) buckets")
            assertSameBytes(staged.r2, expectedR2, "R2 of write at \(buckets) buckets")
        }

        // The single-read form, the records of R1 and then of R2 as one list of 12,000 reads.
        let reads = root.appendingPathComponent("reads.fastq")
        FileManager.default.createFile(atPath: reads.path, contents: nil)
        let handle = try FileHandle(forWritingTo: reads)
        let scratch = root.appendingPathComponent("scratch-reads", isDirectory: true)
        let readCount: Int
        do {
            readCount = try SeededPairOrder.writeReads([r1, r2], to: handle, scratch: scratch, bucketCount: 2)
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        XCTAssertEqual(readCount, 2 * Self.pairCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "the bucket files are gone after writeReads")
        assertSameBytes(
            try Data(contentsOf: reads),
            laidOut(sourceR1 + sourceR2, in: SeededPairOrder.order(count: 2 * Self.pairCount)),
            "writeReads at 2 buckets"
        )
    }
}
