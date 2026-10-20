// FASTQRawLineReaderRetentionTests.swift - the byte line reader must free each chunk it reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

/// `FASTQRawLineReader` reads with `FileHandle.read(upToCount:)`, which
/// returns an autoreleased buffer. The recipe engine counts step outputs with
/// it and writes the mixed layout of a merged recipe through it, each in one
/// job that never drains the pool, so a reader keeping its chunks holds the
/// whole decompressed file (the 2026-10-20 import reached 61 GiB that way
/// through `GzipLineSource`).
final class FASTQRawLineReaderRetentionTests: XCTestCase {
    private static let growthLimit: UInt64 = 16 * 1_048_576

    private var tempDir: URL!
    private var fixture: LargeFASTQFixture!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-line-reader-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fixture = try LargeFASTQFixture(in: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCountingGzipRecordsKeepsMemoryFlat() throws {
        var count = 0
        let growth = try LiveMemoryPeakSampler.peakGrowth {
            count = try FASTQPairInterleaver.countRecords(in: fixture.gzipURL)
        }

        XCTAssertEqual(count, fixture.recordCount)
        assertBounded(growth, path: "FASTQPairInterleaver.countRecords on .gz")
    }

    func testWritingAMergedLayoutKeepsMemoryFlat() throws {
        let sink = try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        defer { try? sink.close() }
        var mergedRecords = 0
        let growth = try LiveMemoryPeakSampler.peakGrowth {
            mergedRecords = try FASTQPairInterleaver.writeMergedThenPairs(
                merged: fixture.gzipURL,
                unmergedR1: nil,
                unmergedR2: nil,
                to: sink
            ).mergedRecords
        }

        XCTAssertEqual(mergedRecords, fixture.recordCount)
        assertBounded(growth, path: "FASTQPairInterleaver.writeMergedThenPairs on .gz")
    }

    private func assertBounded(_ growth: UInt64, path: String, line: UInt = #line) {
        XCTAssertLessThan(
            growth,
            Self.growthLimit,
            "\(path) held \(growth / 1_048_576) MB more live memory after reading "
                + "\(fixture.decompressedBytes / 1_048_576) MB: it is keeping the chunks it read",
            line: line
        )
    }
}
