// DemultiplexOutputWindowMemoryTests.swift - The passes over Cutadapt's outputs keep no window they have read or written
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FIX-MEM-GZIP, F1 of TIMING-RELEASE. The check of placed reads (and the mate pass) reads each output through a 64 KB
// window that reopens the file, and writes each output through a buffer that reopens it. `FileHandle.read(upToCount:)`
// hands back an autoreleased buffer, and the pass runs in one call that never returns to a run loop, so with no pool around
// each window every window stayed in memory until the pass ended: the head's peak grew about 600 B a record on the dual
// route, about 30 GB at 40 M records (SCOPE-AND-DELIVERY:37). The test runs no tool. It reads and writes about 48 MiB in
// one test method, which XCTest wraps in one autorelease pool, as the pass is, and reads this process's footprint around
// each step.

import XCTest
@testable import LungfishWorkflow

final class DemultiplexOutputWindowMemoryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexOutputWindowMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    static let recordCount = 160_000
    static let readLength = 150

    /// Random bases and qualities that records take at different starts, a megabyte apart from any repeat, so gzip
    /// compresses them about as little as real reads.
    struct Pool {
        let bases: [UInt8]
        let qualities: [UInt8]

        init(size: Int = 1 << 20) {
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            var bases = [UInt8](repeating: 0, count: size)
            var qualities = [UInt8](repeating: 0, count: size)
            let alphabet: [UInt8] = Array("ACGT".utf8)
            for index in 0..<size {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bases[index] = alphabet[Int((state >> 33) & 3)]
                qualities[index] = 33 + UInt8((state >> 40) % 41)
            }
            self.bases = bases
            self.qualities = qualities
        }

        func record(_ number: Int) throws -> RawFASTQRecord {
            let start = (number &* 7_919) % (bases.count - DemultiplexOutputWindowMemoryTests.readLength)
            let range = start..<(start + DemultiplexOutputWindowMemoryTests.readLength)
            return try RawFASTQRecord(
                lines: [Array("@r\(number)".utf8), Array(bases[range]), [UInt8(ascii: "+")], Array(qualities[range])],
                file: "made", number: number
            )
        }
    }

    /// How much this process's footprint grew over `body`.
    func growth(_ body: () throws -> Void) throws -> Int64 {
        let before = try ProcessMemorySampler.currentResidentFootprint()
        try body()
        let after = try ProcessMemorySampler.currentResidentFootprint()
        return Int64(after) - Int64(before)
    }

    func fileBytes(_ url: URL) throws -> Int64 {
        Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    }

    /// The most a step may add: a quarter of the bytes it moves through its windows, and at least 8 MiB.
    func ceiling(_ bytes: Int64) -> Int64 { max(8 << 20, bytes / 4) }

    func testTheCursorsAndSinksOfAPassKeepNoWindowTheyReadOrWrote() throws {
        let pool = Pool()
        let plain = dir.appendingPathComponent("out.fastq")
        let gzip = dir.appendingPathComponent("out.fastq.gz")
        do {
            var text: [UInt8] = []
            text.reserveCapacity(Self.recordCount * (2 * Self.readLength + 16))
            for number in 0..<Self.recordCount { text += try pool.record(number).bytes }
            FileManager.default.createFile(atPath: plain.path, contents: Data(text))
            FileManager.default.createFile(atPath: gzip.path, contents: Data(try GzipChunkDeflater().compress(text, finish: true)))
        }
        let plainBytes = try fileBytes(plain)
        let gzipBytes = try fileBytes(gzip)
        XCTAssertGreaterThan(plainBytes, 45 << 20, "the plain output is about 48 MiB")

        func readAll(_ url: URL) throws {
            let cursor = try OrderedOutputCursor(name: "out", url: url)
            var records = 0
            while cursor.head != nil {
                records += 1
                try cursor.advance()
            }
            XCTAssertEqual(records, Self.recordCount, url.lastPathComponent)
        }
        func writeAll(_ url: URL, gzip: Bool) throws {
            var sink = AppendingFASTQSink(url: url, gzip: gzip ? try GzipChunkDeflater() : nil)
            for number in 0..<Self.recordCount { try sink.append(try pool.record(number), flushThreshold: 262_144) }
            try sink.finish()
        }

        let readPlain = try growth { try readAll(plain) }
        let readGzip = try growth { try readAll(gzip) }
        let writePlain = try growth { try writeAll(dir.appendingPathComponent("copy.fastq"), gzip: false) }
        let writeGzip = try growth { try writeAll(dir.appendingPathComponent("copy.fastq.gz"), gzip: true) }
        print("OUTPUTWINDOWS plain \(plainBytes >> 20) MiB, gzip \(gzipBytes >> 20) MiB; growth MiB: read plain \(readPlain >> 20), "
              + "read gzip \(readGzip >> 20), write plain \(writePlain >> 20), write gzip \(writeGzip >> 20)")
        XCTAssertLessThan(readPlain, ceiling(plainBytes), "reading a plain output kept its windows")
        XCTAssertLessThan(readGzip, ceiling(gzipBytes), "reading a gzip output kept its compressed windows")
        XCTAssertLessThan(writePlain, ceiling(plainBytes), "writing a plain output kept what it wrote")
        XCTAssertLessThan(writeGzip, ceiling(gzipBytes), "writing a gzip output kept what it wrote")
        XCTAssertEqual(try fileBytes(dir.appendingPathComponent("copy.fastq")), plainBytes)
    }
}
