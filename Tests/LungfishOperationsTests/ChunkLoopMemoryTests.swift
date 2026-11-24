// ChunkLoopMemoryTests.swift - The Operations loops that read a file in chunks keep no chunk of it (lane POOL-LOOPS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// READID-POOLLESS-CHUNK-LOOPS. A plain file's readData(ofLength:) hands back an autoreleased buffer, so a loop that
// reads a file in chunks in one synchronous stretch, with no pool around each pass, keeps every chunk until its job
// ends and holds the whole file. LungfishOperations runs in the app's process. Each test writes an input of 48 MiB,
// runs the loop through the function its route calls, samples the footprint every 2 ms as
// TaxonomyExtractionOutputReadMemoryTests does, and holds the peak rise to 32 MB.

import Darwin
import Foundation
import Synchronization
import XCTest
@testable import LungfishOperations

final class ChunkLoopMemoryTests: XCTestCase {

    /// The most that the footprint may rise while a loop reads its input: the chunk in hand and the loop's own buffers.
    private static let allowedRise: UInt64 = 32_000_000

    /// The input's size in blocks of a little under 1 MiB of whole records.
    private static let blocks = 48

    /// Merge FASTQ Bundles appends each bundle's reads to the merged file in the app.
    func testTheBundleMergeAppendKeepsNoChunkOfTheInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-loop-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("reads.fastq")
        let record = "@A00123:45:H7KLMDSX5:1:1101:10000:0001 1:N:0:ATCACG\n"
            + String(repeating: "ACGT", count: 37) + "AC\n+\n" + String(repeating: "I", count: 150) + "\n"
        let block = Data(String(repeating: record, count: (1 << 20) / record.utf8.count).utf8)
        FileManager.default.createFile(atPath: input.path, contents: nil)
        let writer = try FileHandle(forWritingTo: input)
        for _ in 0..<Self.blocks { try writer.write(contentsOf: block) }
        try writer.close()
        let merged = root.appendingPathComponent("merged.fastq")
        FileManager.default.createFile(atPath: merged.path, contents: nil)
        let output = try FileHandle(forWritingTo: merged)

        _ = malloc_zone_pressure_relief(nil, 0)
        let baseline = chunkLoopFootprint()
        let sampler = ChunkLoopFootprintSampler()
        sampler.start()
        do { try FASTQBundleMergeService.appendFile(at: input, to: output) } catch {
            _ = sampler.stop()
            throw error
        }
        let peak = sampler.stop()
        let rise = peak > baseline ? peak - baseline : 0
        try output.close()

        let bytes = block.count * Self.blocks
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: merged.path)[.size] as? Int) ?? 0, bytes)
        let loop = "FASTQBundleMergeService.appendFile (FASTQBundleMergeService+Join.swift:26)"
        print("ChunkLoopMemoryTests \(loop): footprint rise \(rise) B over an input of \(bytes) B")
        XCTAssertLessThanOrEqual(
            rise, Self.allowedRise,
            "\(loop) raised the footprint by \(rise) B over an input of \(bytes) B, over the \(Self.allowedRise) B "
                + "that a chunk in hand allows, so it kept its chunks"
        )
    }
}

/// The process's physical footprint, as Activity Monitor's Memory column reads it.
private func chunkLoopFootprint() -> UInt64 {
    var information = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(information.phys_footprint) : 0
}

/// Reads the process's footprint every 2 ms on a thread of its own and keeps the largest reading.
private final class ChunkLoopFootprintSampler: Sendable {
    private let peakBytes = Mutex<UInt64>(0)
    private let stopped = Mutex<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    private let wake = DispatchSemaphore(value: 0)

    func start() {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            while !stopped.withLock({ $0 }) {
                let now = chunkLoopFootprint()
                peakBytes.withLock { $0 = max($0, now) }
                // The cadence of the readings. stop() signals, so the last reading never waits out a period.
                _ = wake.wait(timeout: .now() + .milliseconds(2))
            }
            finished.signal()
        }
    }

    /// Ends the sampling and returns the largest footprint read.
    func stop() -> UInt64 {
        stopped.withLock { $0 = true }
        wake.signal()
        finished.wait()
        return peakBytes.withLock { $0 }
    }
}
