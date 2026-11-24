// TaxonomyExtractionMemoryTests.swift - Extract by taxon holds a few bytes a fragment, and refuses what the Mac cannot hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// READ-IDENTITY-EXTRACT-MEMORY (S1, ruling BIOQA-ROWS-MEMORY items 2 to 6). Extract by taxon scans kraken2's per-read
// output into one table of the fragments it names and then checks the extracted reads against it. The probe measured
// 780 B of footprint a fragment for that route, 15.6 GB at the ordinary 20 M pairs of a host taxon, in the app's own
// process. The first test builds 200,000 single-end reads and 100,000 pairs with 37-character Illumina names, all in
// taxon 9606, scans their kraken2 output and checks an output that equals the input, and holds the footprint's peak
// rise to 200 B a fragment plus 16 MB. The second test pins the refusal in words for a selection the Mac cannot hold,
// which comes before the per-read output is opened.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import Synchronization
@testable import LungfishWorkflow

final class TaxonomyExtractionMemoryTests: XCTestCase {

    // MARK: - The bound on the scan and the check

    func testTheScanAndTheCheckKeepAtMost200BytesAFragmentForSingleEndReadsAndForPairs() async throws {
        let root = try TestTempDirectory.make(prefix: "extraction-memory")
        addTeardownBlock { TestTempDirectory.cleanup(root) }

        // The smaller shape goes first: the heap it frees is not returned to the system at once, and the shape after it
        // would reuse that heap and show a smaller rise.
        try await measure(paired: true, fragments: 100_000, in: root)
        try await measure(paired: false, fragments: 200_000, in: root)
    }

    /// Writes `fragments` reads, or pairs, of taxon 9606 with their kraken2 lines, scans the lines and checks an output
    /// that equals the input, as the route does after seqkit, and asserts the peak rise of the footprint.
    private func measure(paired: Bool, fragments: Int, in root: URL) async throws {
        let shape = paired ? "\(fragments) pairs" : "\(fragments) single-end reads"
        let folder = root.appendingPathComponent(paired ? "pairs" : "single", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kraken = folder.appendingPathComponent("classification.kraken")
        let output = folder.appendingPathComponent("extracted.fastq")
        let sequence = String(repeating: "ACGT", count: 37) + "AC"
        let quality = String(repeating: "I", count: 150)
        let lengthColumn = paired ? "150|150" : "150"
        let hits = paired ? "9606:116 |:| 9606:116" : "9606:116"
        try Self.write(to: kraken, count: fragments) { "C\t\(Self.name($0))\t9606\t\(lengthColumn)\t\(hits)\n" }
        try Self.write(to: output, count: fragments) { index in
            let name = Self.name(index)
            guard paired else { return "@\(name) 1:N:0:ATCACG\n\(sequence)\n+\n\(quality)\n" }
            return "@\(name) 1:N:0:ATCACG\n\(sequence)\n+\n\(quality)\n@\(name) 2:N:0:ATCACG\n\(sequence)\n+\n\(quality)\n"
        }
        let files: [KrakenResultReadSources.File] = paired
            ? [.init(url: folder.appendingPathComponent("r1.fastq"), role: .r1), .init(url: folder.appendingPathComponent("r2.fastq"), role: .r2)]
            : [.init(url: folder.appendingPathComponent("reads.fastq"), role: .reads)]
        let outputs: [URL?] = paired ? [output, nil] : [output]

        let pipeline = TaxonomyExtractionPipeline()
        // The heap that the fixture and the shape before left free goes back to the system, so the baseline is the
        // process's own and a shape cannot reuse what an earlier one freed.
        _ = malloc_zone_pressure_relief(nil, 0)
        let baseline = try XCTUnwrap(ProcessMemoryShare.currentFootprint())
        let sampler = FootprintSampler()
        sampler.start()
        // keraken2 --paired names a pair by its R1 read already, so a paired run trims no mate suffix (extractEachSource).
        let scan = try await pipeline.buildReadIdSet(
            classificationURL: kraken, targetTaxIds: [9606], keepReadPairs: !paired, readLengths: true, progress: nil
        )
        let check = try TaxonomyExtractionPipeline.checkReads(outputs, of: files, named: scan.lengths, matching: .fragmentName)
        let peak = sampler.stop()

        XCTAssertEqual([check.named, check.missing, check.otherLength], [fragments, 0, 0], "\(shape): every fragment is found with its length")
        let rise = peak > baseline ? peak - baseline : 0
        let allowed = UInt64(200 * fragments + 16_000_000)
        print("TaxonomyExtractionMemoryTests \(shape): footprint rise \(rise) B, \(rise / UInt64(fragments)) B a fragment, allowed \(allowed) B")
        XCTAssertLessThanOrEqual(
            rise, allowed,
            "\(shape): the scan and the check raised the footprint by \(rise) B, \(rise / UInt64(fragments)) B a fragment, "
                + "over the \(allowed) B that 200 B a fragment plus 16 MB allow"
        )
    }

    /// The 37 characters of an Illumina read name, unique for each index below one million.
    private static func name(_ index: Int) -> String {
        let tile = String(index % 10_000)
        return "A00123:45:H7KLMDSX5:1:1101:\(10_000 + index / 10_000):" + String(repeating: "0", count: 4 - tile.count) + tile
    }

    /// `count` lines of `line`, written in chunks of 4 MB so the fixture holds no more of the text than a chunk.
    private static func write(to url: URL, count: Int, line: (Int) -> String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var chunk = ""
        for index in 0..<count {
            chunk += line(index)
            if chunk.utf8.count >= 4 << 20 {
                try handle.write(contentsOf: Data(chunk.utf8))
                chunk = ""
            }
        }
        try handle.write(contentsOf: Data(chunk.utf8))
    }

    // MARK: - The refusal

    /// A kreport that puts 60 M reads in Homo sapiens, on a Mac of 16 GiB: 60 M fragments at 200 B are 12 GB, more than
    /// the 8 GiB that half the Mac is. The result has no per-read output at all, so the refusal can only have come from
    /// the kreport, before that file was read. A kreport of 20 M reads (4 GB) is not refused.
    @MainActor
    func testASelectionTooLargeForTheMacRefusesInWordsBeforeThePerReadFileIsRead() async throws {
        let root = try TestTempDirectory.make(prefix: "extraction-refusal")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let resolver = ClassifierReadResolver(memoryShare: ProcessMemoryShare(physicalMemoryBytes: 16 << 30))

        let large = try makeProject(readsOfTheTaxon: 60_000_000, in: root.appendingPathComponent("large", isDirectory: true))
        let refusal = await extractionError(of: resolver, from: large)
        XCTAssertEqual(
            refusal?.localizedDescription,
            "Extracting 60000000 reads of Homo sapiens needs about 11 GB of memory, more than half of this Mac's 16 GB. "
                + "Choose a smaller taxon, or extract these reads on a Mac with more memory."
        )
        XCTAssertEqual(try large.writtenFASTQ(), [], "a refused Extract writes no FASTQ")

        let small = try makeProject(readsOfTheTaxon: 20_000_000, in: root.appendingPathComponent("small", isDirectory: true))
        let other = await extractionError(of: resolver, from: small)
        XCTAssertFalse(
            other?.localizedDescription.contains("of memory") ?? false,
            "20 M reads need 4 GB, under the 8 GiB that half this Mac is: \(other?.localizedDescription ?? "no error")"
        )
    }

    /// A result of one taxon, 9606, with `readsOfTheTaxon` reads in its kreport and no per-read output.
    @MainActor
    private func makeProject(readsOfTheTaxon count: Int, in root: URL) throws -> ReadIdentityProject {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try ReadIdentityProject(root: root)
        try project.writeResult(lengths: ["150"])
        try ["100.00\t\(count)\t0\tR\t1\troot", "100.00\t\(count)\t\(count)\tS\t9606\t  Homo sapiens"]
            .joined(separator: "\n").appending("\n")
            .write(to: project.resultFolder.appendingPathComponent("classification.kreport"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: project.resultFolder.appendingPathComponent("classification.kraken"))
        return project
    }

    /// The error that Extract of taxon 9606 into a file raises for `project`, nil when it ends without one.
    @MainActor
    private func extractionError(of resolver: ClassifierReadResolver, from project: ReadIdentityProject) async -> Error? {
        do {
            _ = try await resolver.resolveAndExtract(
                tool: .kraken2, resultPath: project.resultFolder, selections: [ClassifierRowSelector(taxIds: [9606])],
                options: ExtractionOptions(), destination: .file(project.output.appendingPathComponent("host.fastq"))
            )
            return nil
        } catch {
            return error
        }
    }
}

/// Reads the process's footprint every 2 ms on a thread of its own and keeps the largest reading.
private final class FootprintSampler: Sendable {
    private struct State {
        var peakBytes: UInt64 = 0
        var stopped = false
    }

    private let state = Mutex(State())
    private let finished = DispatchSemaphore(value: 0)

    func start() {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            while !state.withLock({ $0.stopped }) {
                if let now = ProcessMemoryShare.currentFootprint() {
                    state.withLock { $0.peakBytes = max($0.peakBytes, now) }
                }
                usleep(2_000)
            }
            finished.signal()
        }
    }

    /// Ends the sampling and returns the largest footprint read.
    func stop() -> UInt64 {
        state.withLock { $0.stopped = true }
        finished.wait()
        return state.withLock { $0.peakBytes }
    }
}
