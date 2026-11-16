// SeededPairOrderMemoryTests.swift - the seeded staging holds a few buckets in memory, never the whole read set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row FASTP-STAGING-MEMORY (ruling BIO-ROWS-1-3, items 3 and 4). SeededPairOrder spills the pairs to bucket files and
// then loads one bucket at a time, so its comment and its 64 MiB bucket target say memory stays bounded. On the
// 19,279,040-pair D1b input lungfish-cli peaked at 10.7 GB (fastq trim) and 11.1 GB (Viral Recon staging), which is
// 555 to 700 bytes a pair and about the whole staged text. Each bucket's Foundation objects (the NSData of the file
// read and of every unpacked chunk) went to an autorelease pool that nothing drained until the job returned.
//
// The test stages 1 GiB of synthetic pairs through both write forms with 16 buckets, so a bucket holds about 64 MiB,
// and reads the process's own `phys_footprint` on a second thread. The peak must stay within four buckets (256 MiB)
// of where the run began. The sinks are /dev/null, so the staged bytes cost no memory or disk, and the source files
// and the bucket files together stay under about 2 GiB of disk and are removed in tearDown.

import XCTest
import Darwin
import LungfishTestSupport
@testable import LungfishWorkflow

final class SeededPairOrderMemoryTests: XCTestCase {

    private var root: URL!

    /// Read length of the synthetic reads. 600,000 pairs of 2 x 450 bases are 1.03 GiB of FASTQ text.
    private static let readLength = 450
    private static let pairCount = 600_000
    private static let bucketCount = 16
    /// Four buckets of 64 MiB, the most the staging may add to the footprint at the start of the run.
    private static let allowedRise: UInt64 = 256 << 20

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "seeded-pair-order-memory")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testStagingOneGiBOfPairsKeepsTheFootprintWithinFourBuckets() throws {
        let r1 = root.appendingPathComponent("synthetic_R1.fastq")
        let r2 = root.appendingPathComponent("synthetic_R2.fastq")
        try Self.writeSyntheticPairs(r1: r1, r2: r2, pairs: Self.pairCount, readLength: Self.readLength)
        let sourceBytes = try Self.byteCount(r1) + Self.byteCount(r2)
        XCTAssertGreaterThanOrEqual(sourceBytes, 1 << 30, "the input is at least 1 GiB of pairs")

        // Pairs: both mates of every pair go to their own sink, in the seeded order.
        let pairSinks = (try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null")), try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null")))
        defer { for sink in [pairSinks.0, pairSinks.1] { try? sink.close() } }
        let pairRun = FootprintSampler()
        pairRun.start()
        let pairs: Int
        do {
            pairs = try SeededPairOrder.write(
                .separate(r1: r1, r2: r2), r1: pairSinks.0, r2: pairSinks.1,
                scratch: root.appendingPathComponent("pair-order", isDirectory: true), bucketCount: Self.bucketCount
            )
        } catch {
            _ = pairRun.stop()
            throw error
        }
        let pairResult = pairRun.stop()
        XCTAssertEqual(pairs, Self.pairCount)
        XCTAssertLessThan(
            pairResult.rise, Self.allowedRise,
            "SeededPairOrder.write of \(sourceBytes >> 20) MiB of pairs in \(Self.bucketCount) buckets raised the footprint "
                + "by \(pairResult.riseText) (start \(pairResult.startText), peak \(pairResult.peakText) at "
                + "\(pairResult.peakAtPercent)% of the run), over the four buckets \(Self.allowedRise >> 20) MiB it may hold"
        )

        // Single reads, the form Viral Recon uses for a bundle of unpaired or mixed reads.
        let readSink = try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        defer { try? readSink.close() }
        let readRun = FootprintSampler()
        readRun.start()
        let reads: Int
        do {
            reads = try SeededPairOrder.writeReads(
                [r1, r2], to: readSink,
                scratch: root.appendingPathComponent("read-order", isDirectory: true), bucketCount: Self.bucketCount
            )
        } catch {
            _ = readRun.stop()
            throw error
        }
        let readResult = readRun.stop()
        XCTAssertEqual(reads, 2 * Self.pairCount)
        XCTAssertLessThan(
            readResult.rise, Self.allowedRise,
            "SeededPairOrder.writeReads of \(sourceBytes >> 20) MiB of reads in \(Self.bucketCount) buckets raised the footprint "
                + "by \(readResult.riseText) (start \(readResult.startText), peak \(readResult.peakText) at "
                + "\(readResult.peakAtPercent)% of the run), over the four buckets \(Self.allowedRise >> 20) MiB it may hold"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("pair-order").path)
                || FileManager.default.fileExists(atPath: root.appendingPathComponent("read-order").path),
            "the bucket files are gone when the staging returns"
        )
    }

    // MARK: - Footprint

    /// This process's own `phys_footprint`, which Activity Monitor shows as Memory, or 0 when the kernel does not answer.
    private static func currentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// What one sampled run measured.
    private struct FootprintResult {
        let start: UInt64
        let peak: UInt64
        let peakAtPercent: Int

        var rise: UInt64 { peak > start ? peak - start : 0 }
        var startText: String { Self.mebibytes(start) }
        var peakText: String { Self.mebibytes(peak) }
        var riseText: String { Self.mebibytes(rise) }

        private static func mebibytes(_ bytes: UInt64) -> String { "\(bytes >> 20) MiB" }
    }

    /// Reads the footprint every couple of milliseconds on a second thread, from `start()` until `stop()`. The pacing
    /// is a timed wait on a semaphore that `stop()` signals, so the thread ends as soon as the run does and the test
    /// sleeps nowhere.
    private final class FootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private let stopSignal = DispatchSemaphore(value: 0)
        private let ended = DispatchSemaphore(value: 0)
        private let startBytes: UInt64
        private var peakBytes: UInt64
        private var peakNanoseconds: UInt64 = 0
        private var startNanoseconds: UInt64 = 0
        private var endNanoseconds: UInt64 = 0

        init() {
            startBytes = SeededPairOrderMemoryTests.currentFootprint()
            peakBytes = startBytes
        }

        func start() {
            startNanoseconds = DispatchTime.now().uptimeNanoseconds
            let worker = Thread { [self] in
                while true {
                    record(SeededPairOrderMemoryTests.currentFootprint())
                    if stopSignal.wait(timeout: .now() + .milliseconds(2)) == .success { break }
                }
                record(SeededPairOrderMemoryTests.currentFootprint())
                ended.signal()
            }
            worker.stackSize = 1 << 20
            worker.start()
        }

        func stop() -> FootprintResult {
            stopSignal.signal()
            ended.wait()
            lock.lock()
            defer { lock.unlock() }
            endNanoseconds = DispatchTime.now().uptimeNanoseconds
            let length = max(1, endNanoseconds - startNanoseconds)
            let at = peakNanoseconds > startNanoseconds ? peakNanoseconds - startNanoseconds : 0
            return FootprintResult(start: startBytes, peak: peakBytes, peakAtPercent: Int(min(100, at * 100 / length)))
        }

        private func record(_ footprint: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            if footprint > peakBytes {
                peakBytes = footprint
                peakNanoseconds = DispatchTime.now().uptimeNanoseconds
            }
        }
    }

    // MARK: - Synthetic pairs

    private static func byteCount(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Writes `pairs` records to each of `r1` and `r2` in 8 MiB pieces, so the generator never holds more than that.
    /// Every read is a slice of a random base template at its own offset, with a binned quality line of long runs, so
    /// the text is realistic in size and the bucket files compress about as the reads of a real run do.
    static func writeSyntheticPairs(r1: URL, r2: URL, pairs: Int, readLength: Int) throws {
        var state: UInt64 = 0x1234_5678_9ABC_DEF1
        func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let span = 1 << 16
        let alphabet = Array("ACGT".utf8)
        var bases: [UInt8] = []
        bases.reserveCapacity(span + readLength)
        for _ in 0..<(span + readLength) { bases.append(alphabet[Int(next() & 3)]) }
        let binned = Array("?@FI".utf8)
        var qualities: [UInt8] = []
        qualities.reserveCapacity(span + readLength)
        while qualities.count < span + readLength {
            let value = binned[Int(next() & 3)]
            qualities.append(contentsOf: repeatElement(value, count: 20 + Int(next() % 40)))
        }
        qualities.removeLast(qualities.count - (span + readLength))

        for (url, mate) in [(r1, 1), (r2, 2)] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var buffer: [UInt8] = []
            buffer.reserveCapacity((8 << 20) + 4096)
            for index in 0..<pairs {
                let baseOffset = Int(next() % UInt64(span))
                let qualityOffset = Int(next() % UInt64(span))
                buffer += Array("@synthetic.\(index)/\(mate)\n".utf8)
                buffer += bases[baseOffset..<baseOffset + readLength]
                buffer += Array("\n+\n".utf8)
                buffer += qualities[qualityOffset..<qualityOffset + readLength]
                buffer.append(0x0A)
                if buffer.count >= 8 << 20 {
                    try autoreleasepool { try handle.write(contentsOf: Data(buffer)) }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try autoreleasepool { try handle.write(contentsOf: Data(buffer)) }
        }
    }
}
