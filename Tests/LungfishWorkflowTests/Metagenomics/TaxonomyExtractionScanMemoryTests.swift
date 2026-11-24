// TaxonomyExtractionScanMemoryTests.swift - The scan of kraken2's per-read output keeps no chunk of the file it reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// READ-IDENTITY-EXTRACT-MEMORY (S1, still open after lane READID-MEM-2). The Release re-measure PROBE-READID-REL2 found
// that a kraken2 output with real-length hit lists costs one more byte of footprint for each byte of the file. The extra
// shows only at the scan's peak and is freed when the scan ends. That is the signature of the plain-file loop of
// buildReadIdSet, which reads 1 MiB chunks with FileHandle.readData(ofLength:) and had no autoreleasepool. A plain
// file's read hands back an autoreleased chunk, so a loop that never leaves its job keeps every chunk until the scan
// ends (the gzip path is pooled already). The test below writes a plain per-read output of 134 MB (128 MiB) with lines
// as long as the probe's long hit lists make them (194 B), gives it a taxon that only six lines carry so the table
// stays small, scans it as the route does with the lengths kept, and holds the peak rise of the footprint to 32 MB.

import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxonomyExtractionScanMemoryTests: XCTestCase {

    /// The most that the footprint may rise while the scan reads the output. It is the chunk in hand, the scan's own
    /// buffers and the six reads that match, and a small part of the file.
    private static let allowedRise: UInt64 = 32_000_000

    /// The blocks of the output file. A block holds whole lines and a little under 1 MiB, so 128 of them are 128 MiB.
    private static let blocks = 128

    /// The taxon that the scan is asked for and that a few lines carry, and the taxon of every other line.
    private static let targetTaxon = 562
    private static let otherTaxon = 9606

    /// The blocks that one line of the target taxon goes in front of.
    private static let targetBlocks: Set<Int> = [0, 25, 50, 75, 100, 125]

    func testTheScanOfAPlainPerReadOutputKeepsNoChunkOfItAfterItIsRead() async throws {
        let root = try TestTempDirectory.make(prefix: "extraction-scan")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let kraken = root.appendingPathComponent("classification.kraken")
        let written = try Self.writeOutput(to: kraken)
        XCTAssertGreaterThanOrEqual(written.bytes, 128_000_000, "the output is at least 128 MB")
        let meanLine = written.bytes / UInt64(written.lines)
        XCTAssertTrue((190...198).contains(meanLine), "the lines are as long as the probe's long hit lists make them, not \(meanLine) B")
        let pipeline = TaxonomyExtractionPipeline()

        var scan: (ids: Set<String>, lengths: ReadLengthTable)?
        let rise = try await peakRise {
            // kraken2 --paired names a pair by its R1 read already, so a paired run trims no mate suffix.
            scan = try await pipeline.buildReadIdSet(
                classificationURL: kraken, targetTaxIds: [Self.targetTaxon], keepReadPairs: false, readLengths: true,
                progress: nil
            )
        }

        let found = try XCTUnwrap(scan)
        XCTAssertEqual(found.lengths.count, Self.targetBlocks.count, "the scan names the lines of the target taxon")
        XCTAssertTrue(found.ids.isEmpty, "the route that checks lengths keeps the IDs in its table alone")
        print("TaxonomyExtractionScanMemoryTests scan: footprint rise \(rise) B over an output of \(written.bytes) B")
        XCTAssertLessThanOrEqual(
            rise, Self.allowedRise,
            "the scan of an output of \(written.bytes) B raised the footprint by \(rise) B, over the "
                + "\(Self.allowedRise) B that a chunk in hand and the scan's buffers allow, so it kept its chunks"
        )
    }

    // MARK: - Helpers

    /// Runs `pass` while a thread reads the footprint, and returns how far the largest reading rose above the footprint
    /// before the pass began.
    private func peakRise(of pass: () async throws -> Void) async throws -> UInt64 {
        // The heap that the fixture left free goes back to the system, so the baseline is the process's own.
        _ = malloc_zone_pressure_relief(nil, 0)
        let baseline = try XCTUnwrap(ProcessMemoryShare.currentFootprint())
        let sampler = ScanFootprintSampler()
        sampler.start()
        do {
            try await pass()
        } catch {
            _ = sampler.stop()
            throw error
        }
        let peak = sampler.stop()
        return peak > baseline ? peak - baseline : 0
    }

    /// Writes the per-read output of a paired run, `blocks` blocks of whole lines one block at a time, and returns its
    /// size and its line count. A block is lines of the other taxon with a long hit list each, and one line of the
    /// target taxon goes in front of each block of `targetBlocks`.
    private static func writeOutput(to url: URL) throws -> (bytes: UInt64, lines: Int) {
        let hits = hitLists()
        let linesPerBlock = (1 << 20) / line(index: 0, taxon: otherTaxon, hits: hits[0]).utf8.count
        var text = ""
        text.reserveCapacity(1 << 20)
        for index in 0..<linesPerBlock {
            text += line(index: index, taxon: otherTaxon, hits: hits[index % hits.count])
        }
        let block = Data(text.utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var bytes: UInt64 = 0
        var lines = 0
        for number in 0..<blocks {
            if targetBlocks.contains(number) {
                let target = Data(line(index: linesPerBlock + number, taxon: targetTaxon, hits: hits[number % hits.count]).utf8)
                try handle.write(contentsOf: target)
                bytes += UInt64(target.count)
                lines += 1
            }
            try handle.write(contentsOf: block)
            bytes += UInt64(block.count)
            lines += linesPerBlock
        }
        return (bytes, lines)
    }

    /// One line of the per-read output of a paired run: classified, the 37-character name, the taxon, the two mates'
    /// lengths and the hit list.
    private static func line(index: Int, taxon: Int, hits: String) -> String {
        "C\t\(name(index))\t\(taxon)\t150|150\t\(hits)\n"
    }

    /// The 37 characters of an Illumina read name, unique for each index below one million.
    private static func name(_ index: Int) -> String {
        let tile = String(index % 10_000)
        return "A00123:45:H7KLMDSX5:1:1101:\(10_000 + index / 10_000):" + String(repeating: "0", count: 4 - tile.count) + tile
    }

    /// Four hit lists of 140 characters, in the shape that kraken2 writes for a pair of 150-base mates: each mate's
    /// k-mers in groups `taxid:count`, and the two mates joined by ` |:| `. With the 54 other characters of the line it
    /// is 194 B, 119 B longer than the line with the short list `9606:116 |:| 9606:116`, as in the probe's long set.
    private static func hitLists() -> [String] {
        let first = "9606:21 0:14 9605:4 9606:33 131567:9 9606:18 2759:6 9606:12 7711:13"
        let second = "0:13 9606:44 9604:11 9606:19 33208:5 9606:27 9605:12 9606:15 2759:21"
        func reversed(_ mate: String) -> String { mate.split(separator: " ").reversed().joined(separator: " ") }
        return [
            "\(first) |:| \(second)", "\(second) |:| \(first)",
            "\(reversed(first)) |:| \(reversed(second))", "\(reversed(second)) |:| \(reversed(first))",
        ]
    }
}

/// Reads the process's footprint every 2 ms on a thread of its own and keeps the largest reading.
private final class ScanFootprintSampler: Sendable {
    private let peakBytes = Mutex<UInt64>(0)
    private let stopped = Mutex<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)

    func start() {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            while !stopped.withLock({ $0 }) {
                if let now = ProcessMemoryShare.currentFootprint() {
                    peakBytes.withLock { $0 = max($0, now) }
                }
                usleep(2_000)
            }
            finished.signal()
        }
    }

    /// Ends the sampling and returns the largest footprint read.
    func stop() -> UInt64 {
        stopped.withLock { $0 = true }
        finished.wait()
        return peakBytes.withLock { $0 }
    }
}
