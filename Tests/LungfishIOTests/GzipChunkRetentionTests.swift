// GzipChunkRetentionTests.swift - streaming readers must free each chunk they read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Regression for the 2026-10-20 import kill: `FileHandle.readData(ofLength:)`
/// returns an autoreleased buffer, and a read loop that never leaves its
/// thread (an async job with no suspension point, or a synchronous call)
/// never drains the pool. Counting the reads of a 30 GB `.gz` R1 kept every
/// decompressed 1 MB chunk alive, the CLI reached 61 GiB on a 48 GiB Mac and
/// macOS killed it. Each read path must keep memory flat however much it reads.
final class GzipChunkRetentionTests: XCTestCase {
    /// About 35 MB decompressed. A loop that keeps its chunks grows by all of
    /// it; one that frees them holds a chunk, a partial line and one chunk's lines.
    private static let growthLimit: UInt64 = 16 * 1_048_576

    private var tempDir: URL!
    private var fixture: LargeFASTQFixture!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gzip-chunk-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fixture = try LargeFASTQFixture(in: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The path that failed in the import. An async job cannot sit inside an
    /// autorelease pool, so a regression here frees its chunks on a cooperative
    /// thread while the next test runs; this test still fails on its own.
    func testCountingGzipRecordsKeepsMemoryFlat() async throws {
        let reader = FASTQReader(validateSequence: false)
        let sampler = LiveMemoryPeakSampler()
        let count = try await reader.countRecords(in: fixture.gzipURL)
        let growth = sampler.stop()

        XCTAssertEqual(count, fixture.recordCount)
        assertBounded(growth, path: "FASTQReader.countRecords on .gz")
    }

    func testGzipLineIterationKeepsMemoryFlat() throws {
        var lines = 0
        let growth = try LiveMemoryPeakSampler.peakGrowth {
            try fixture.gzipURL.forEachLineAutoDecompressing { _ in lines += 1 }
        }

        XCTAssertEqual(lines, fixture.recordCount * 4)
        assertBounded(growth, path: "forEachLineAutoDecompressing on .gz")
    }

    func testGzipChunkIterationKeepsMemoryFlat() throws {
        var bytes: UInt64 = 0
        let growth = try LiveMemoryPeakSampler.peakGrowth {
            try fixture.gzipURL.forEachChunkAutoDecompressing { bytes += UInt64($0.count) }
        }

        XCTAssertEqual(bytes, fixture.decompressedBytes)
        assertBounded(growth, path: "forEachChunkAutoDecompressing on .gz")
    }

    func testPlainLineIterationKeepsMemoryFlat() throws {
        var lines = 0
        let growth = try LiveMemoryPeakSampler.peakGrowth {
            try fixture.plainURL.forEachLineAutoDecompressing { _ in lines += 1 }
        }

        XCTAssertEqual(lines, fixture.recordCount * 4)
        assertBounded(growth, path: "forEachLineAutoDecompressing on plain text")
    }

    func testPlainChunkIterationKeepsMemoryFlat() throws {
        var bytes: UInt64 = 0
        let growth = try LiveMemoryPeakSampler.peakGrowth {
            try fixture.plainURL.forEachChunkAutoDecompressing { bytes += UInt64($0.count) }
        }

        XCTAssertEqual(bytes, fixture.decompressedBytes)
        assertBounded(growth, path: "forEachChunkAutoDecompressing on plain text")
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
