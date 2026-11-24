// ChunkLoopMemoryTests.swift - The Workflow loops that read a file in chunks keep no chunk of it (lane POOL-LOOPS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// READID-POOLLESS-CHUNK-LOOPS. A plain file's read(upToCount:) and readData(ofLength:) hand back an autoreleased
// buffer, so a loop that reads a file in chunks in one synchronous stretch, with no pool around each pass, keeps every
// chunk until its job ends and holds the whole file. Each test below writes an input of 48 MiB, runs one loop through
// the function its route calls, samples the process's footprint every 2 ms as TaxonomyExtractionOutputReadMemoryTests
// does, and holds the peak rise to 32 MB. The printed rise is the loop's measured footprint against its input size.

import Darwin
import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class ChunkLoopMemoryTests: XCTestCase {

    /// The most that the footprint may rise while a loop reads its input: the chunk in hand and the loop's own buffers.
    private static let allowedRise: UInt64 = 32_000_000

    /// The input's size in blocks of a little under 1 MiB of whole records.
    private static let blocks = 48

    // MARK: - BAMToFASTQConverter.swift

    /// The by-ID and by-region extractions write the records samtools left unflagged through this writer.
    func testTheUnflaggedRecordWriterKeepsNoChunkOfTheSAMText() throws {
        let root = try makeRoot()
        let sam = root.appendingPathComponent("unflagged.sam")
        let record = "A00123:45:H7KLMDSX5:1:1101:10000:0001\t4\t*\t0\t0\t*\t*\t0\t0\t"
            + String(repeating: "ACGT", count: 37) + "AC\t" + String(repeating: "I", count: 150) + "\n"
        let written = try Self.writeBlocks(of: record, to: sam)
        let fastq = root.appendingPathComponent("out.fastq")
        FileManager.default.createFile(atPath: fastq.path, contents: nil)
        let output = try FileHandle(forWritingTo: fastq)
        defer { try? output.close() }

        var records = 0
        let rise = try peakRise {
            records = try UnflaggedRecordFASTQWriter.writeRecords(fromSAMText: sam, to: output)
        }

        XCTAssertEqual(records, written.records, "every SAM line became a record")
        assertKeepsNoChunk("UnflaggedRecordFASTQWriter.writeRecords (BAMToFASTQConverter.swift:204)", input: written.bytes, rise: rise)
    }

    /// The by-ID extraction joins the mate sidecars after the unflagged records.
    func testTheSplitFASTQJoinKeepsNoChunkOfASidecar() throws {
        let root = try makeRoot()
        let sam = root.appendingPathComponent("unflagged.sam")
        FileManager.default.createFile(atPath: sam.path, contents: nil)
        let sidecar = root.appendingPathComponent("read1.fastq")
        let written = try Self.writeFASTQ(to: sidecar)
        let output = root.appendingPathComponent("out.fastq")

        let rise = try peakRise {
            try writeSplitFASTQ(unflaggedSAM: sam, sidecars: [sidecar], to: output)
        }

        XCTAssertEqual(try Self.size(of: output), written.bytes, "the output holds every byte of the sidecar")
        assertKeepsNoChunk("writeSplitFASTQ (BAMToFASTQConverter.swift:343)", input: written.bytes, rise: rise)
    }

    /// The read extraction and the demultiplexer append one file to another here.
    func testTheFileAppendKeepsNoChunkOfItsSource() throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("part.fastq")
        let written = try Self.writeFASTQ(to: source)
        let destination = root.appendingPathComponent("joined.fastq")

        let rise = try peakRise {
            try appendFileContents(of: source, to: destination)
        }

        XCTAssertEqual(try Self.size(of: destination), written.bytes, "the destination holds every byte of the source")
        assertKeepsNoChunk("appendFileContents (BAMToFASTQConverter.swift:403)", input: written.bytes, rise: rise)
    }

    // MARK: - ResolvedSequenceInputs.swift

    /// A multi-file bundle, an ONT import, is joined into one file before a mapper reads it.
    func testTheMultiFileBundleJoinKeepsNoChunkOfAMember() throws {
        let root = try makeRoot()
        let bundle = root.appendingPathComponent("Project.lungfish/Imports/multi.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        var total = 0
        for index in 0..<2 {
            let name = "run_\(index).fastq"
            let written = try Self.writeFASTQ(to: chunks.appendingPathComponent(name), blocks: Self.blocks / 2)
            total += written.bytes
            entries.append(.init(filename: "chunks/\(name)", originalPath: "/orig/\(name)", sizeBytes: Int64(written.bytes), isSymlink: false))
        }
        try Data("@p\nA\n+\nI\n".utf8).write(to: bundle.appendingPathComponent("preview.fastq"))
        try FASTQSourceFileManifest(files: entries).save(to: bundle)
        let joinDirectory = root.appendingPathComponent("join", isDirectory: true)

        var joined: URL?
        let rise = try peakRise {
            joined = try ResolvedSequenceInputs.concatenateMultiFileBundle(bundle, into: joinDirectory)?.outputURL
        }

        XCTAssertEqual(try Self.size(of: try XCTUnwrap(joined)), total, "the joined file holds every byte of both members")
        assertKeepsNoChunk("ResolvedSequenceInputs.concatenateMultiFileBundle (ResolvedSequenceInputs.swift:332)", input: total, rise: rise)
    }

    // MARK: - FASTQReadsExport.swift

    /// Export FASTQ of a bundle of plain chunk files joins their bytes.
    func testTheReadsExportJoinKeepsNoChunkOfAChunkFile() async throws {
        let root = try makeRoot()
        var chunkURLs: [URL] = []
        var total = 0
        for index in 0..<2 {
            let url = root.appendingPathComponent("chunk_\(index).fastq")
            total += try Self.writeFASTQ(to: url, blocks: Self.blocks / 2).bytes
            chunkURLs.append(url)
        }
        let source = FASTQReadsExport.Source(bundleURL: root, isDerived: false, chunkURLs: chunkURLs, inputURLs: chunkURLs)
        let staged = root.appendingPathComponent("staged.fastq")

        let rise = try await peakRiseAsync {
            try await FASTQReadsExport.write(source, to: staged, outputIsGzip: false)
        }

        XCTAssertEqual(try Self.size(of: staged), total, "the export holds every byte of both chunk files")
        assertKeepsNoChunk("FASTQReadsExport.write (FASTQReadsExport.swift:161)", input: total, rise: rise)
    }

    // MARK: - BundleAlignmentTrackRemovalRecord.swift

    /// Remove Alignment Track hashes the BAM it removes for the record.
    func testTheRemovedTrackHashKeepsNoChunkOfTheBAM() throws {
        let root = try makeRoot()
        let bam = root.appendingPathComponent("track.bam")
        let written = try Self.writeFASTQ(to: bam)

        var descriptor: ProvenanceFileDescriptor?
        let rise = try peakRise {
            descriptor = try BundleAlignmentTrackRemovalRecord.removedFileDescriptor(for: bam)
        }

        XCTAssertEqual(descriptor?.fileSize, UInt64(written.bytes), "the descriptor states the whole file")
        assertKeepsNoChunk("BundleAlignmentTrackRemovalRecord.removedFileDescriptor (BundleAlignmentTrackRemovalRecord.swift:69)", input: written.bytes, rise: rise)
    }

    // MARK: - AssemblyContigCatalog.swift

    /// The assembly viewer's catalog reads the contig FASTA's headers.
    func testTheContigHeaderScanKeepsNoChunkOfTheFASTA() throws {
        let root = try makeRoot()
        let fasta = root.appendingPathComponent("contigs.fasta")
        FileManager.default.createFile(atPath: fasta.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fasta)
        let line = String(repeating: "ACGTTGCA", count: 10) + "\n"
        let body = Data(String(repeating: line, count: (1 << 20) / line.utf8.count).utf8)
        var total = 0
        for index in 0..<Self.blocks {
            let header = Data(">contig_\(index) length=\(body.count)\n".utf8)
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: body)
            total += header.count + body.count
        }
        try handle.close()

        var headers: [String: String] = [:]
        let rise = try peakRise {
            headers = try AssemblyContigCatalog.parseHeaders(from: fasta)
        }

        XCTAssertFalse(headers.isEmpty, "the scan found the headers")
        assertKeepsNoChunk("AssemblyContigCatalog.parseHeaders (AssemblyContigCatalog.swift:235)", input: total, rise: rise)
    }

    // MARK: - MetagenomicsDatabaseRegistry.swift

    /// Plugin Manager's database download checks the archive it fetched, many gigabytes for a Kraken2 database.
    func testTheDatabaseArchiveChecksumKeepsNoChunkOfTheArchive() throws {
        let root = try makeRoot()
        let archive = root.appendingPathComponent("k2_viral.tar.gz")
        let written = try Self.writeFASTQ(to: archive)

        var digest = ""
        let rise = try peakRise {
            digest = try MetagenomicsDatabaseRegistry.fileChecksum(archive, .sha256)
        }

        XCTAssertEqual(digest.count, 64, "the digest is a SHA-256")
        assertKeepsNoChunk("MetagenomicsDatabaseRegistry.fileChecksum (MetagenomicsDatabaseRegistry.swift:1335)", input: written.bytes, rise: rise)
    }

    // MARK: - The loops POOL-LOOPS left unmeasured (lane POOL-LOOPS-2)

    /// Split by Name joins the parts it wrote into one file of reads.
    func testTheSplitByNameJoinKeepsNoChunkOfAPart() throws {
        let root = try makeRoot()
        let part = root.appendingPathComponent("part.fastq")
        let written = try Self.writeFASTQ(to: part)
        let target = root.appendingPathComponent("joined.fastq")

        var records = 0
        let rise = try peakRise { records = try FASTQSplitByNameRunner.join([part], into: target) }

        XCTAssertEqual(records, written.records, "the join counted every record")
        assertKeepsNoChunk("FASTQSplitByNameRunner.join (FASTQSplitByNameRunner.swift:323)", input: written.bytes, rise: rise)
    }

    /// Import FASTQ with fastp interleaves the pairs and appends the reads that lost their mate.
    func testTheFastpInterleaveKeepsNoChunkOfTheUnpairedReads() throws {
        let root = try makeRoot()
        let mate = "@A00123:45:H7KLMDSX5:1:1101:10000:0001\nACGT\n+\nIIII\n"
        let r1 = root.appendingPathComponent("r1.fastq")
        let r2 = root.appendingPathComponent("r2.fastq")
        try Data(mate.utf8).write(to: r1)
        try Data(mate.utf8).write(to: r2)
        let unpaired = root.appendingPathComponent("unpaired.fastq")
        let written = try Self.writeFASTQ(to: unpaired)
        let target = root.appendingPathComponent("interleaved.fastq")

        var expected = 0
        let rise = try peakRise {
            expected = try FastpPairedRunner.writeInterleaved(r1: r1, r2: r2, appending: unpaired, to: target)
        }

        XCTAssertEqual(expected, written.records + 2, "the pair and every unpaired read are counted")
        assertKeepsNoChunk("FastpPairedRunner.writeInterleaved (FastpPairedRunner.swift:536)", input: written.bytes, rise: rise)
    }

    /// The full-length ONT MHC genotyping copies and hashes its FASTA input before it runs.
    func testTheMHCInputSnapshotKeepsNoChunkOfTheFASTA() throws {
        let root = try makeRoot()
        let fasta = root.appendingPathComponent("reads.fasta")
        let written = try Self.writeBlocks(of: ">read_1\n" + String(repeating: "ACGT", count: 50) + "\n", to: fasta)
        let snapshot = root.appendingPathComponent("snapshot.fasta")

        let rise = try peakRise { _ = try FullLengthONTMHCFASTAInputSnapshotter().snapshot(sourceURL: fasta, to: snapshot) }

        XCTAssertEqual(try Self.size(of: snapshot), written.bytes, "the snapshot holds every byte")
        assertKeepsNoChunk("FullLengthONTMHCFASTAInputSnapshotter.snapshot (FullLengthONTMHCFASTAInputSnapshotter.swift:51)", input: written.bytes, rise: rise)
    }

    /// The Illumina amplicon genotyping joins the merged and unmerged reads.
    func testTheAmpliconPairJoinKeepsNoChunkOfASource() throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("merged.fastq")
        let written = try Self.writeFASTQ(to: source)
        let destination = root.appendingPathComponent("joined.fastq")

        var records = 0
        let rise = try peakRise { records = try IlluminaAmpliconPairMerger.concatenate(sources: [source], into: destination) }

        XCTAssertEqual(records, written.records, "the join counted every record")
        assertKeepsNoChunk("IlluminaAmpliconPairMerger.concatenate (IlluminaAmpliconPairMerger.swift:624)", input: written.bytes, rise: rise)
    }

    /// Orient Reads reads vsearch's per-read table line by line.
    func testTheOrientTableScanKeepsNoChunkOfTheTable() throws {
        let root = try makeRoot()
        let table = root.appendingPathComponent("orient.tsv")
        let written = try Self.writeBlocks(of: "A00123:45:H7KLMDSX5:1:1101:10000:0001\t+\tref_1\t98.5\n", to: table)

        var lines = 0
        let rise = try peakRise { try OrientPipeline(runner: nil).streamLines(in: table) { _ in lines += 1 } }

        XCTAssertEqual(lines, written.records, "every line came through")
        assertKeepsNoChunk("OrientPipeline.streamLines (OrientPipeline.swift:435)", input: written.bytes, rise: rise)
    }

    /// Opening an assembly result counts each contig's G and C bases from the contig FASTA.
    func testTheContigGCCountKeepsNoChunkOfTheContig() throws {
        let root = try makeRoot()
        let fasta = root.appendingPathComponent("contigs.fasta")
        let header = Data(">contig_1\n".utf8)
        FileManager.default.createFile(atPath: fasta.path, contents: header)
        let line = String(repeating: "ACGTTGCA", count: 10) + "\n"
        let perBlock = (1 << 20) / line.utf8.count
        let written = try Self.appendBlocks(of: line, to: fasta)
        let entry = FASTAIndex.Entry(
            name: "contig_1", length: 80 * perBlock * Self.blocks, offset: header.count, lineBases: 80, lineWidth: 81
        )
        let handle = try FileHandle(forReadingFrom: fasta)
        defer { try? handle.close() }

        var gc: Int64 = 0
        let rise = try peakRise { gc = try AssemblyContigCatalog.gcBaseCount(for: entry, fileHandle: handle) }

        XCTAssertEqual(gc, Int64(40 * perBlock * Self.blocks), "half of every line is G or C")
        assertKeepsNoChunk("AssemblyContigCatalog.gcBaseCount (AssemblyContigCatalog.swift:341)", input: written, rise: rise)
    }

    /// The NAO-MGS import partitions its virus hits by sample, line by line.
    func testTheNaoMgsSampleScanKeepsNoChunkOfTheHits() throws {
        let root = try makeRoot()
        let hits = root.appendingPathComponent("virus_hits.tsv")
        let written = try Self.writeBlocks(of: "sample_1\tA00123:45:H7KLMDSX5:1:1101:10000:0001\t11676\tNC_001802.1\t150\n", to: hits)

        var lines = 0
        let rise = try peakRise { try streamNaoMgsLines(from: hits) { _, _ in lines += 1 } }

        XCTAssertGreaterThanOrEqual(lines, written.records, "every line came through")
        assertKeepsNoChunk("streamNaoMgsLines (NaoMgsSamplePartitioner.swift:244)", input: written.bytes, rise: rise)
    }

    // MARK: - Helpers

    /// Appends `blocks` blocks of `line` to the file at `url` and returns the bytes appended.
    private static func appendBlocks(of line: String, to url: URL) throws -> Int {
        let block = Data(String(repeating: line, count: (1 << 20) / line.utf8.count).utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for _ in 0..<blocks { try handle.write(contentsOf: block) }
        return block.count * blocks
    }

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

    private func peakRiseAsync(_ pass: () async throws -> Void) async throws -> UInt64 {
        _ = malloc_zone_pressure_relief(nil, 0)
        let baseline = chunkLoopFootprint()
        let sampler = ChunkLoopFootprintSampler()
        sampler.start()
        do { try await pass() } catch {
            _ = sampler.stop()
            throw error
        }
        let peak = sampler.stop()
        return peak > baseline ? peak - baseline : 0
    }

    /// Writes a FASTQ of 150-base reads, `blocks` blocks of whole records, and returns its size and record count.
    private static func writeFASTQ(to url: URL, blocks: Int = blocks) throws -> (bytes: Int, records: Int) {
        let record = "@A00123:45:H7KLMDSX5:1:1101:10000:0001 1:N:0:ATCACG\n"
            + String(repeating: "ACGT", count: 37) + "AC\n+\n" + String(repeating: "I", count: 150) + "\n"
        return try writeBlocks(of: record, to: url, blocks: blocks)
    }

    private static func writeBlocks(of record: String, to url: URL, blocks: Int = blocks) throws -> (bytes: Int, records: Int) {
        let perBlock = (1 << 20) / record.utf8.count
        let block = Data(String(repeating: record, count: perBlock).utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for _ in 0..<blocks { try handle.write(contentsOf: block) }
        return (block.count * blocks, perBlock * blocks)
    }

    private static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
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
