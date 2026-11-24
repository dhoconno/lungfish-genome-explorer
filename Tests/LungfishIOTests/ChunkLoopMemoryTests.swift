// ChunkLoopMemoryTests.swift - The IO loops that read a file in chunks keep no chunk of it (lane POOL-LOOPS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// READID-POOLLESS-CHUNK-LOOPS. A plain file's read(upToCount:) and readData(ofLength:) hand back an autoreleased
// buffer, so a loop that reads a file in chunks in one synchronous stretch, with no pool around each pass, keeps every
// chunk until its job ends and holds the whole file. Each test writes an input of 48 MiB, runs the loop through the
// function its route calls, samples the footprint every 2 ms as TaxonomyExtractionOutputReadMemoryTests does, and holds
// the peak rise to 32 MB. The printed rise is the loop's measured footprint against its input size.

import Darwin
import Foundation
import Synchronization
import XCTest
@testable import LungfishIO

final class ChunkLoopMemoryTests: XCTestCase {

    /// The most that the footprint may rise while a loop reads its input: the chunk in hand and the loop's own buffers.
    private static let allowedRise: UInt64 = 32_000_000

    /// The input's size in blocks of a little under 1 MiB of whole lines.
    private static let blocks = 48

    /// A derived bundle's payload checksum hashes the whole FASTQ (demultiplex, orient and the derivative writers).
    func testThePayloadChecksumKeepsNoChunkOfTheFile() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("reads.fastq")
        let written = try Self.writeBlocks(
            of: "@A00123:45:H7KLMDSX5:1:1101:10000:0001 1:N:0:ATCACG\n" + String(repeating: "ACGT", count: 37) + "AC\n+\n"
                + String(repeating: "I", count: 150) + "\n",
            to: file
        )

        var digest = ""
        let rise = try peakRise { digest = try PayloadChecksum.sha256Hex(fileAt: file) }

        XCTAssertEqual(digest.count, 64, "the digest is a SHA-256")
        assertKeepsNoChunk("PayloadChecksum.sha256Hex (FASTQDerivedBundleManifest.swift:92)", input: written.bytes, rise: rise)
    }

    /// The Kraken2 result viewer and the extraction read the per-read output, which is as long as the reads.
    func testTheKrakenOutputParserKeepsNoChunkOfTheOutput() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("classification.kraken")
        let written = try Self.writeBlocks(of: "C\tA00123:45:H7KLMDSX5:1:1101:10000:0001\t9606\t150\t9606:116\n", to: file)

        var parsed = 0
        let rise = try peakRise { parsed = try Kraken2OutputParser.parseRecords(url: file) { _ in } }

        XCTAssertEqual(parsed, written.lines, "every line is a record")
        assertKeepsNoChunk("Kraken2OutputParser.parseRecords (Kraken2OutputParser.swift:173)", input: written.bytes, rise: rise)
    }

    /// Import of a VCF streams its plain lines into the variant database.
    func testTheVCFLineStreamKeepsNoChunkOfTheFile() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("calls.vcf")
        let written = try Self.writeBlocks(of: "chr1\t12345\t.\tA\tG\t50\tPASS\tDP=100;AF=0.5\tGT:DP\t0/1:100\n", to: file)

        var lines = 0
        let rise = try peakRise { _ = try VariantDatabase.streamPlainLines(url: file) { _ in lines += 1 } }

        XCTAssertEqual(lines, written.lines, "every line came through")
        assertKeepsNoChunk("VariantDatabase.streamPlainLines (VariantDatabase+RegionExtraction.swift:638)", input: written.bytes, rise: rise)
    }

    /// The NAO-MGS import names its taxa from the taxonomy's names.dmp, about 250 MB.
    func testTheTaxonomyNameScanKeepsNoChunkOfNamesDmp() throws {
        let root = try makeRoot()
        let written = try Self.writeBlocks(of: "9606\t|\tHomo sapiens\t|\t\t|\tscientific name\t|\n", to: root.appendingPathComponent("names.dmp"))

        var names: [Int: String] = [:]
        let rise = try peakRise { names = try TaxonomyNameResolver.resolveFromFile(root, taxIds: [9606]) }

        XCTAssertEqual(names[9606], "Homo sapiens", "the scan found the name")
        assertKeepsNoChunk("TaxonomyNameResolver.resolveFromFile (TaxonomyNameResolver.swift:93)", input: written.bytes, rise: rise)
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-loop-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func assertKeepsNoChunk(_ loop: String, input: Int, rise: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        print("ChunkLoopMemoryTests \(loop): footprint rise \(rise) B over an input of \(input) B")
        XCTAssertLessThanOrEqual(
            rise, Self.allowedRise,
            "\(loop) raised the footprint by \(rise) B over an input of \(input) B, over the \(Self.allowedRise) B "
                + "that a chunk in hand allows, so it kept its chunks",
            file: file, line: line
        )
    }

    /// Runs `pass` while a thread reads the footprint, and returns how far the largest reading rose above the
    /// footprint before the pass began.
    private func peakRise(_ pass: () throws -> Void) throws -> UInt64 {
        _ = malloc_zone_pressure_relief(nil, 0)
        let baseline = chunkLoopFootprint()
        let sampler = ChunkLoopFootprintSampler()
        sampler.start()
        do { try pass() } catch {
            _ = sampler.stop()
            throw error
        }
        let peak = sampler.stop()
        return peak > baseline ? peak - baseline : 0
    }

    private static func writeBlocks(of line: String, to url: URL) throws -> (bytes: Int, lines: Int) {
        let perBlock = (1 << 20) / line.utf8.count
        let block = Data(String(repeating: line, count: perBlock).utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for _ in 0..<blocks { try handle.write(contentsOf: block) }
        return (block.count * blocks, perBlock * blocks)
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
