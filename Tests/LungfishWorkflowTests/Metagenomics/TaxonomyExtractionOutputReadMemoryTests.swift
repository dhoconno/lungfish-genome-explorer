// TaxonomyExtractionOutputReadMemoryTests.swift - The two reads of an extract's output keep no chunk of it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// READ-IDENTITY-EXTRACT-MEMORY (S1, still open after lane READID-MEM). After the read check, Extract by taxon reads the
// file it extracted twice from start to end. ClassifierReadResolver.concatenateFiles joins the pairs file and the reads
// file in 4 MiB chunks, and ClassifierReadResolver.countFASTQRecords counts the joined file in 1 MiB chunks. A plain
// file's read(upToCount:) hands back an autoreleased buffer, so a loop that never leaves its job kept every chunk of
// both passes. The Release CLI held 2.1 times the output (15.0 GB at 20 M reads), and 99.97% of its heap was those
// chunks. Each test below writes an output of 210 MB, runs one pass through its own entry point as the route does, and
// holds the peak rise of the footprint to 64 MB.

import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxonomyExtractionOutputReadMemoryTests: XCTestCase {

    /// The most that the footprint may rise while a pass reads the output. It is the chunk in hand and the pass's own
    /// buffers, and a small part of the file.
    private static let allowedRise: UInt64 = 64_000_000

    /// The blocks of the output file. A block holds whole records and a little under 1 MiB, so 201 of them are more
    /// than 200 MiB.
    private static let blocks = 201

    // MARK: - The 4 MiB pass

    /// The join of the pairs file and the reads file into the one file that the route goes on with.
    func testTheJoinOfTheExtractedFilesKeepsNoChunkOfTheOutputAfterItIsWritten() async throws {
        let root = try TestTempDirectory.make(prefix: "extraction-output-join")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let output = root.appendingPathComponent("kraken2-reads.fastq")
        let joined = root.appendingPathComponent("kraken2-concat.fastq")
        let written = try Self.writeOutput(to: output)
        XCTAssertGreaterThanOrEqual(written.bytes, 200 << 20, "the output is at least 200 MiB")
        let resolver = ClassifierReadResolver()

        let rise = try await peakRise {
            try await resolver.concatenateFiles([output], into: joined)
        }

        XCTAssertEqual(try Self.size(of: joined), written.bytes, "the joined file holds every byte of the output")
        print("TaxonomyExtractionOutputReadMemoryTests join: footprint rise \(rise) B over an output of \(written.bytes) B")
        XCTAssertLessThanOrEqual(
            rise, Self.allowedRise,
            "the join of an output of \(written.bytes) B raised the footprint by \(rise) B, over the "
                + "\(Self.allowedRise) B that a chunk in hand and the join's buffers allow, so it kept its chunks"
        )
    }

    // MARK: - The 1 MiB pass

    /// The count of the reads of the joined file, which the route reports and checks against zero.
    func testTheCountOfTheJoinedFileKeepsNoChunkOfTheOutputAfterItIsCounted() async throws {
        let root = try TestTempDirectory.make(prefix: "extraction-output-count")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let output = root.appendingPathComponent("kraken2-concat.fastq")
        let written = try Self.writeOutput(to: output)
        XCTAssertGreaterThanOrEqual(written.bytes, 200 << 20, "the output is at least 200 MiB")
        let resolver = ClassifierReadResolver()

        var counted = 0
        let rise = try await peakRise {
            counted = try await resolver.countFASTQRecords(in: output)
        }

        XCTAssertEqual(counted, written.records, "the count is the number of records in the output")
        print("TaxonomyExtractionOutputReadMemoryTests count: footprint rise \(rise) B over an output of \(written.bytes) B")
        XCTAssertLessThanOrEqual(
            rise, Self.allowedRise,
            "the count of an output of \(written.bytes) B raised the footprint by \(rise) B, over the "
                + "\(Self.allowedRise) B that a chunk in hand and the count's buffers allow, so it kept its chunks"
        )
    }

    // MARK: - The 1 MiB pass of the FASTA conversion

    /// The conversion of the joined file to FASTA, which the route takes when a person asks for FASTA. It reads the whole
    /// joined file through the line reader, in 1 MiB chunks of `read(upToCount:)`, in one synchronous call, the same API
    /// and loop as the join and the count above. READID-MEM-2 review SF1.
    func testTheFASTAConversionOfTheJoinedFileKeepsNoChunkOfTheOutputAfterItIsRead() async throws {
        let root = try TestTempDirectory.make(prefix: "extraction-output-fasta")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let output = root.appendingPathComponent("kraken2-concat.fastq")
        let converted = root.appendingPathComponent("kraken2-concat.fasta")
        let written = try Self.writeOutput(to: output)
        XCTAssertGreaterThanOrEqual(written.bytes, 200 << 20, "the output is at least 200 MiB")
        let resolver = ClassifierReadResolver()

        let rise = try await peakRise {
            try await resolver.convertFASTQToFASTA(input: output, output: converted)
        }

        // A record of 356 B less its 2 B plus line and its 151 B quality line is 203 B in FASTA.
        XCTAssertEqual(
            try Self.size(of: converted), UInt64(written.records * 203),
            "the FASTA holds the name line and the bases line of every record"
        )
        print("TaxonomyExtractionOutputReadMemoryTests fasta: footprint rise \(rise) B over an output of \(written.bytes) B")
        XCTAssertLessThanOrEqual(
            rise, Self.allowedRise,
            "the FASTA conversion of an output of \(written.bytes) B raised the footprint by \(rise) B, over the "
                + "\(Self.allowedRise) B that a chunk in hand and the line reader's buffers allow, so it kept its chunks"
        )
    }

    // MARK: - Helpers

    /// Runs `pass` while a thread reads the footprint, and returns how far the largest reading rose above the footprint
    /// before the pass began.
    private func peakRise(of pass: () async throws -> Void) async throws -> UInt64 {
        // The heap that the fixture left free goes back to the system, so the baseline is the process's own.
        _ = malloc_zone_pressure_relief(nil, 0)
        let baseline = try XCTUnwrap(ProcessMemoryShare.currentFootprint())
        let sampler = OutputReadFootprintSampler()
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

    /// Writes a FASTQ of 150-base reads with 37-character names, `blocks` blocks of whole records one block at a time,
    /// and returns its size and its record count.
    private static func writeOutput(to url: URL) throws -> (bytes: UInt64, records: Int) {
        let record = "@A00123:45:H7KLMDSX5:1:1101:10000:0001 1:N:0:ATCACG\n"
            + String(repeating: "ACGT", count: 37) + "AC\n+\n"
            + String(repeating: "I", count: 150) + "\n"
        let recordsPerBlock = (1 << 20) / record.utf8.count
        let block = Data(String(repeating: record, count: recordsPerBlock).utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for _ in 0..<blocks {
            try handle.write(contentsOf: block)
        }
        return (UInt64(block.count * blocks), recordsPerBlock * blocks)
    }

    private static func size(of url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }
}

/// Reads the process's footprint every 2 ms on a thread of its own and keeps the largest reading.
private final class OutputReadFootprintSampler: Sendable {
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
