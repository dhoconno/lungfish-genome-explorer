// MatrixMarketReaderMemoryTests.swift - A plain matrix is read in chunks and never held whole (Phase 5.2 fix FIX-RS-SC-IMPORT-F3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// STARsolo writes `matrix.mtx` as plain text, so its import reads the file through `FileHandle.read(upToCount:)`, one
// 1 MiB chunk a call, and each chunk is autoreleased. A CLI import runs the whole read inside one autorelease pool, so
// every chunk lived until the read ended and the footprint rose by the size of the file. The probe of lane RS-SC-IMPORT
// found a STARsolo import above the 10x import of the same cells for that reason (`SCR/lanes/RS-SC-IMPORT.md`,
// milestone 3, F3). The footprint is read inside one test method, so nothing drains the method's pool between the two
// readings, as in `RNASeqResultWriterTests`.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO

final class MatrixMarketReaderMemoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "matrix-market-memory") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// One entry line is 16 bytes, so 64 blocks of 65,536 lines make 64 MiB.
    private static let entryLine = "100000 10000 42\n"
    private static let linesPerBlock = 1 << 16
    private static let blocks = 64
    private static let growthBound: Int64 = 16 << 20

    /// A plain matrix of 64 MiB of entry lines behind its header, written one block at a time.
    private func writePlainMatrix(to url: URL) throws -> MatrixMarketSize {
        let size = MatrixMarketSize(rows: 200_000, columns: 20_000, entries: Self.linesPerBlock * Self.blocks)
        try Data("\(MatrixMarketReader.header)\n\(size.rows) \(size.columns) \(size.entries)\n".utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let block = Data(String(repeating: Self.entryLine, count: Self.linesPerBlock).utf8)
        for _ in 0..<Self.blocks { try autoreleasepool { try handle.write(contentsOf: block) } }
        return size
    }

    func testAPlainMatrixOf64MiBIsReadInChunksAndNotHeldWhole() throws {
        let url = root.appendingPathComponent("matrix.mtx")
        let size = try autoreleasepool { try writePlainMatrix(to: url) }
        let before = try XCTUnwrap(ProcessMemoryShare.currentFootprint())
        let reader = try MatrixMarketReader(url: url)
        defer { reader.close() }
        var batch = MatrixMarketBatch(capacity: 4096)
        var count = 0
        var sum: UInt64 = 0
        while try reader.next(&batch) {
            count += batch.count
            for index in 0..<batch.count { sum += batch.values[index] }
        }
        let after = try XCTUnwrap(ProcessMemoryShare.currentFootprint())
        let growth = Int64(after) - Int64(before)
        XCTAssertLessThan(growth, Self.growthBound, "reading a plain 64 MiB matrix grew the footprint by \(growth) bytes")
        XCTAssertFalse(reader.isGzip)
        XCTAssertEqual(reader.size, size)
        XCTAssertEqual(count, size.entries)
        XCTAssertEqual(sum, UInt64(size.entries) * 42)
    }
}
