// GzipChunkRetentionTests.swift - streaming readers must free each chunk they read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Regression for the 2026-10-20 import kill: `FileHandle.readData(ofLength:)`
/// returns an autoreleased buffer, and a read loop that never leaves its
/// thread (an async job with no suspension point, or a synchronous call)
/// never drains the pool. Counting the reads of a 30 GB `.gz` R1 kept every
/// decompressed 1 MB chunk alive, the CLI reached 61 GiB on a 48 GiB Mac and
/// macOS killed it. Each read path must keep memory flat however much it reads.
final class GzipChunkRetentionTests: XCTestCase {
    /// About 35 MB decompressed. A loop that keeps its chunks grows by all of
    /// it; one that frees them holds a chunk, a partial line and one chunk's lines.
    private static let recordsPerBlock = 4_096
    private static let blocks = 40
    private static let recordCount = recordsPerBlock * blocks
    private static let growthLimit: UInt64 = 16 * 1_048_576

    private var tempDir: URL!
    private var plainURL: URL!
    private var gzipURL: URL!
    private var decompressedBytes: UInt64 = 0

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gzip-chunk-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        plainURL = tempDir.appendingPathComponent("reads.fastq")
        gzipURL = tempDir.appendingPathComponent("reads.fastq.gz")

        let seq = String(repeating: "ACGT", count: 25)
        let qual = String(repeating: "I", count: 100)
        var block = ""
        for i in 0..<Self.recordsPerBlock {
            block += "@read\(i) 1:N:0\n\(seq)\n+\n\(qual)\n"
        }
        let blockData = Data(block.utf8)
        FileManager.default.createFile(atPath: plainURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: plainURL)
        for _ in 0..<Self.blocks {
            try handle.write(contentsOf: blockData)
        }
        try handle.close()
        decompressedBytes = UInt64(blockData.count * Self.blocks)

        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-1", "-k", "-f", plainURL.path]
        try gzip.run()
        gzip.waitUntilExit()
        XCTAssertEqual(gzip.terminationStatus, 0)
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
        let count = try await reader.countRecords(in: gzipURL)
        let growth = sampler.stop()

        XCTAssertEqual(count, Self.recordCount)
        assertBounded(growth, path: "FASTQReader.countRecords on .gz")
    }

    func testGzipLineIterationKeepsMemoryFlat() throws {
        var lines = 0
        let growth = try peakGrowth { try gzipURL.forEachLineAutoDecompressing { _ in lines += 1 } }

        XCTAssertEqual(lines, Self.recordCount * 4)
        assertBounded(growth, path: "forEachLineAutoDecompressing on .gz")
    }

    func testGzipChunkIterationKeepsMemoryFlat() throws {
        var bytes: UInt64 = 0
        let growth = try peakGrowth { try gzipURL.forEachChunkAutoDecompressing { bytes += UInt64($0.count) } }

        XCTAssertEqual(bytes, decompressedBytes)
        assertBounded(growth, path: "forEachChunkAutoDecompressing on .gz")
    }

    func testPlainLineIterationKeepsMemoryFlat() throws {
        var lines = 0
        let growth = try peakGrowth { try plainURL.forEachLineAutoDecompressing { _ in lines += 1 } }

        XCTAssertEqual(lines, Self.recordCount * 4)
        assertBounded(growth, path: "forEachLineAutoDecompressing on plain text")
    }

    func testPlainChunkIterationKeepsMemoryFlat() throws {
        var bytes: UInt64 = 0
        let growth = try peakGrowth { try plainURL.forEachChunkAutoDecompressing { bytes += UInt64($0.count) } }

        XCTAssertEqual(bytes, decompressedBytes)
        assertBounded(growth, path: "forEachChunkAutoDecompressing on plain text")
    }

    /// The peak growth while `body` runs. The surrounding pool drains whatever
    /// `body` left autoreleased before the next test starts, so one leaking
    /// path cannot free its chunks during the next test and hide that test's leak.
    private func peakGrowth(_ body: () throws -> Void) throws -> UInt64 {
        try autoreleasepool {
            let sampler = LiveMemoryPeakSampler()
            try body()
            return sampler.stop()
        }
    }

    private func assertBounded(_ growth: UInt64, path: String, line: UInt = #line) {
        XCTAssertLessThan(
            growth,
            Self.growthLimit,
            "\(path) held \(growth / 1_048_576) MB more live memory after reading "
                + "\(decompressedBytes / 1_048_576) MB: it is keeping the chunks it read",
            line: line
        )
    }
}

/// Polls the bytes malloc has live on a background thread and reports the
/// peak growth over the value at creation. Live bytes, not the footprint:
/// pages an earlier test freed stay cached in the footprint, and a leaking
/// read that reuses them would show no footprint growth at all.
private final class LiveMemoryPeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private let baseline: UInt64
    private var peak: UInt64
    private var running = true

    init() {
        baseline = Self.liveBytes()
        peak = baseline
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while lock.withLock({ running }) {
                let live = Self.liveBytes()
                lock.withLock { peak = max(peak, live) }
                usleep(1_000)
            }
            finished.signal()
        }
    }

    /// Stops sampling and returns the peak growth in bytes.
    func stop() -> UInt64 {
        let live = Self.liveBytes()
        lock.withLock {
            peak = max(peak, live)
            running = false
        }
        finished.wait()
        return lock.withLock { peak > baseline ? peak - baseline : 0 }
    }

    private static func liveBytes() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return UInt64(statistics.size_in_use)
    }
}
