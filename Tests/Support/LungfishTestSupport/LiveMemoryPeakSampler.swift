// LiveMemoryPeakSampler.swift - peak live malloc bytes while a reader streams a file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Polls the bytes malloc has live on a background thread and reports the
/// peak growth over the value at creation. Live bytes, not the footprint:
/// pages an earlier test freed stay cached in the footprint, and a leaking
/// read that reuses them would show no footprint growth at all.
public final class LiveMemoryPeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private let baseline: UInt64
    private var peak: UInt64
    private var running = true

    public init() {
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
    public func stop() -> UInt64 {
        let live = Self.liveBytes()
        lock.withLock {
            peak = max(peak, live)
            running = false
        }
        finished.wait()
        return lock.withLock { peak > baseline ? peak - baseline : 0 }
    }

    /// The peak growth while `body` runs. The surrounding pool drains whatever
    /// `body` left autoreleased before the caller goes on, so one leaking path
    /// cannot free its chunks during the next test and hide that test's leak.
    public static func peakGrowth(_ body: () throws -> Void) throws -> UInt64 {
        try autoreleasepool {
            let sampler = LiveMemoryPeakSampler()
            try body()
            return sampler.stop()
        }
    }

    private static func liveBytes() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return UInt64(statistics.size_in_use)
    }
}

/// A FASTQ of identical four-line records, written plain and gzipped, large
/// enough that a reader keeping its chunks stands out from one that frees them.
public struct LargeFASTQFixture {
    public let plainURL: URL
    public let gzipURL: URL
    public let recordCount: Int
    public let decompressedBytes: UInt64

    /// Writes `blocks` blocks of `recordsPerBlock` records (about 870 KB per
    /// block) to `directory` and gzips a copy at level 1.
    public init(in directory: URL, recordsPerBlock: Int = 4_096, blocks: Int = 40) throws {
        plainURL = directory.appendingPathComponent("reads.fastq")
        gzipURL = directory.appendingPathComponent("reads.fastq.gz")
        recordCount = recordsPerBlock * blocks

        let seq = String(repeating: "ACGT", count: 25)
        let qual = String(repeating: "I", count: 100)
        var block = ""
        for i in 0..<recordsPerBlock {
            block += "@read\(i) 1:N:0\n\(seq)\n+\n\(qual)\n"
        }
        let blockData = Data(block.utf8)
        FileManager.default.createFile(atPath: plainURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: plainURL)
        for _ in 0..<blocks {
            try handle.write(contentsOf: blockData)
        }
        try handle.close()
        decompressedBytes = UInt64(blockData.count * blocks)

        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-1", "-k", "-f", plainURL.path]
        try gzip.run()
        gzip.waitUntilExit()
        guard gzip.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
