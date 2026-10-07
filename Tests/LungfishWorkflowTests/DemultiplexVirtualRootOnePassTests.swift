// DemultiplexVirtualRootOnePassTests.swift - A group of virtual barcode bundles is rebuilt from its root in one pass
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The cutadapt engine's virtual mode rebuilt each barcode bundle's preview
// and the FASTQ its cached statistics come from one bundle at a time, each
// reading the whole root for the statistics and again for the preview until
// it was complete. Since a multi-file root is every chunk (final review B1),
// a chunked ONT import with 96 barcodes was read about 190 times. The
// pipeline now folds up to eight bundles into one plan and reads the root
// files once per group (R3). This fixture holds three bundles, so it is
// one pass. DemultiplexVirtualRootGroupedRebuildTests covers two groups.
// The per-barcode code is copied below from DemultiplexingPipeline
// at 336e77cd1 as the reference the one pass must match byte for byte, on a
// multi-file root and on a single-file root, with mate-specific trims,
// reverse-complemented reads, a read ID that repeats in the root, a read two
// bundles list and previews that complete before the root ends. Only the
// pipeline test runs tools, and it skips without cutadapt and seqkit.

import Foundation
import os
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Counts how often each root file is opened and how many records are read.
private final class RootReadCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (opens: [String: Int](), records: 0))

    var opens: [String: Int] { state.withLock { $0.opens } }
    var records: Int { state.withLock { $0.records } }

    func opens(of url: URL) -> Int { opens[url.standardizedFileURL.path] ?? 0 }

    /// The pipeline's root reader, counted.
    var source: VirtualRootRecordSource {
        { url in
            self.state.withLock { $0.opens[url.standardizedFileURL.path, default: 0] += 1 }
            let records = DemultiplexingPipeline.fileRootRecordSource(url)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await record in records {
                            self.state.withLock { $0.records += 1 }
                            continuation.yield(record)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

// MARK: - The per-barcode reference, as it stood at 336e77cd1, with mates kept apart

extension DemultiplexingPipeline {
    /// `writeVirtualPreviewFASTQ` at 336e77cd1, with the mates of a pair kept
    /// apart (A9, D6). It reads root files through `rootRecordSource`, whose
    /// default is the `FASTQReader` it used. It kept one record per read ID,
    /// the last mate seen of a pair. Now a read ID listed twice previews both
    /// mates in order, and one listed once its first mate. A single read
    /// listed twice is written twice, as before.
    func perBarcodeReferencePreview(
        fromRootFASTQs rootFASTQs: [URL],
        orderedReadIDs: [String],
        trimEntries: [DemuxTrimEntry],
        orientMap: [String: String],
        outputURL: URL
    ) async throws {
        guard !orderedReadIDs.isEmpty else { return }

        var trimMap: [String: DemuxTrimEntry] = [:]
        for entry in trimEntries {
            trimMap["\(entry.readID)\t\(entry.mate)"] = entry
        }

        var listings: [String: Int] = [:]
        for listedID in orderedReadIDs {
            listings[Self.fragmentID(ofListedID: listedID), default: 0] += 1
        }
        func holds(_ mates: [Int: FASTQRecord]?, _ count: Int) -> Bool {
            guard let mates else { return false }
            return mates[0] != nil || mates.count >= min(count, 2)
        }
        var transformedRecords: [String: [Int: FASTQRecord]] = [:]

        rootFiles: for rootFASTQ in rootFASTQs {
            for try await record in rootRecordSource(rootFASTQ) {
                let rawReadName = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
                let (readID, mate) = detectMate(rawReadName: rawReadName)
                guard listings[readID] != nil else { continue }

                var outputRecord = record
                if let trim = trimMap["\(readID)\t\(mate)"] ?? trimMap["\(readID)\t0"] {
                    let trimEnd = max(trim.trim5p, outputRecord.length - trim.trim3p)
                    outputRecord = outputRecord.trimmed(from: trim.trim5p, to: trimEnd)
                }
                if orientMap[readID] == "-" {
                    outputRecord = outputRecord.reverseComplement()
                }
                transformedRecords[readID, default: [:]][mate] = outputRecord

                if listings.allSatisfy({ holds(transformedRecords[$0.key], $0.value) }) {
                    break rootFiles
                }
            }
        }

        let writer = FASTQWriter(url: outputURL)
        try writer.open()
        defer { try? writer.close() }

        var matesWritten: [String: Int] = [:]
        for listedID in orderedReadIDs {
            let readID = Self.fragmentID(ofListedID: listedID)
            guard let mates = transformedRecords[readID] else { continue }
            let record: FASTQRecord?
            if listedID != readID {
                record = mates[listedID.hasSuffix("/1") ? 1 : 2]
            } else if let single = mates[0] {
                record = single
            } else {
                let ordered = mates.keys.sorted()
                let next = matesWritten[readID, default: 0]
                record = next < ordered.count ? mates[ordered[next]] : nil
                matesWritten[readID] = next + 1
            }
            if let record {
                try writer.write(record)
            }
        }
    }

    /// `writeVirtualStatisticsFASTQ` at 336e77cd1, reading as above.
    func perBarcodeReferenceStatistics(
        fromRootFASTQs rootFASTQs: [URL],
        orderedReadIDs: [String],
        trimEntries: [DemuxTrimEntry],
        orientMap: [String: String],
        outputURL: URL
    ) async throws {
        guard !orderedReadIDs.isEmpty else { return }

        var trimMap: [String: DemuxTrimEntry] = [:]
        for entry in trimEntries {
            trimMap["\(entry.readID)\t\(entry.mate)"] = entry
        }

        let selectedReadIDs = Set(orderedReadIDs)
        let writer = FASTQWriter(url: outputURL)
        try writer.open()
        defer { try? writer.close() }

        for rootFASTQ in rootFASTQs {
            for try await record in rootRecordSource(rootFASTQ) {
                let rawReadName = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
                let (readID, mate) = detectMate(rawReadName: rawReadName)
                guard selectedReadIDs.contains(readID) else { continue }

                var outputRecord = record
                if let trim = trimMap["\(readID)\t\(mate)"] ?? trimMap["\(readID)\t0"] {
                    let trimEnd = max(trim.trim5p, outputRecord.length - trim.trim3p)
                    outputRecord = outputRecord.trimmed(from: trim.trim5p, to: trimEnd)
                }
                if orientMap[readID] == "-" {
                    outputRecord = outputRecord.reverseComplement()
                }
                try writer.write(outputRecord)
            }
        }
    }
}

// MARK: - Tests

final class DemultiplexVirtualRootOnePassTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-virtual-root-one-pass")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The root's records, as two chunks. `dup` repeats with three
    /// sequences, `p1` is a mate pair named the Illumina way, and `shared`
    /// is listed by BC01 and by unassigned.
    private static let firstChunk: [(name: String, sequence: String)] = [
        ("a1", "ACGTACGTACGTAAAACCCC"),
        ("b1", "TTTTGGGGCCCCAAAATTTT"),
        ("dup", "GATTACAGATTACAGATTAC"),
        ("a2", "CCCCGGGGAAAATTTTACGT"),
        ("p1 1:N:0:ACGT", "AAAAACCCCCGGGGGTTTTT"),
        ("p1 2:N:0:ACGT", "TTTTTGGGGGCCCCCAAAAA"),
        ("u1", "ACACACACACGTGTGTGTGT"),
    ]
    private static let secondChunk: [(name: String, sequence: String)] = [
        ("b2", "GGGGAAAACCCCTTTTGGGG"),
        ("dup", "CATCATCATCATCATCATCA"),
        ("a3", "TACGTACGTACGTACGTACG"),
        ("shared", "AACCGGTTAACCGGTTAACC"),
        ("u2", "GTGTGTGTGTACACACACAC"),
        ("dup", "TGATGATGATGATGATGATG"),
        ("b3", "CAGTCAGTCAGTCAGTCAGT"),
    ]
    private static var rootRecordCount: Int { firstChunk.count + secondChunk.count }

    /// Qualities that differ along each read, so trims and reverse complements show in them.
    private static func fastq(_ reads: [(name: String, sequence: String)]) -> String {
        let alphabet = Array("!+5?I:3A")
        return reads.enumerated().map { index, read in
            let quality = String((0..<read.sequence.count).map { alphabet[($0 + index) % alphabet.count] })
            return "@\(read.name)\n\(read.sequence)\n+\n\(quality)\n"
        }.joined()
    }

    private func writeRoot(multiFile: Bool) throws -> [URL] {
        let folder = root.appendingPathComponent(multiFile ? "multi" : "single", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if multiFile {
            let chunks = [folder.appendingPathComponent("run_0.fastq"), folder.appendingPathComponent("run_1.fastq")]
            try Self.fastq(Self.firstChunk).write(to: chunks[0], atomically: true, encoding: .utf8)
            try Self.fastq(Self.secondChunk).write(to: chunks[1], atomically: true, encoding: .utf8)
            return chunks
        }
        let file = folder.appendingPathComponent("reads.fastq")
        try Self.fastq(Self.firstChunk + Self.secondChunk).write(to: file, atomically: true, encoding: .utf8)
        return [file]
    }

    private struct BarcodeBundle {
        let name: String
        let orderedReadIDs: [String]
        let previewLimit: Int
        let trimEntries: [DemultiplexingPipeline.DemuxTrimEntry]
        let orientMap: [String: String]
        /// Read counts of the statistics FASTQ, the bundle's listed records in root order.
        let expectedReadCount: Int
        /// The preview's records, in preview order.
        let expectedPreview: [String]
    }

    private static func trim(_ readID: String, mate: Int, _ trim5p: Int, _ trim3p: Int) -> DemultiplexingPipeline.DemuxTrimEntry {
        DemultiplexingPipeline.DemuxTrimEntry(readID: readID, mate: mate, trim5p: trim5p, trim3p: trim3p, rootReadLength: nil)
    }

    /// BC01 has mate-specific trims, a trim listed twice and a trim for a
    /// read it does not list. BC02's preview completes on the root's last
    /// record after `dup` was seen three times. Unassigned shares `shared`.
    private static let bundles: [BarcodeBundle] = [
        BarcodeBundle(
            name: "BC01",
            orderedReadIDs: ["a1", "a2", "p1", "p1", "a3", "shared"],
            previewLimit: 2,
            trimEntries: [
                trim("a1", mate: 0, 2, 3), trim("a2", mate: 0, 1, 0), trim("a2", mate: 0, 4, 2),
                trim("p1", mate: 1, 3, 1), trim("p1", mate: 0, 2, 2), trim("shared", mate: 0, 0, 5),
                trim("x9", mate: 0, 1, 1),
            ],
            orientMap: ["a2": "-", "p1": "-", "a3": "+"],
            expectedReadCount: 6,
            expectedPreview: ["a1", "a2"]
        ),
        BarcodeBundle(
            name: "BC02",
            orderedReadIDs: ["dup", "b3", "b1", "b2"],
            previewLimit: 2,
            trimEntries: [trim("dup", mate: 0, 1, 1), trim("b2", mate: 1, 2, 0)],
            orientMap: ["dup": "-"],
            expectedReadCount: 6,
            expectedPreview: ["dup", "b3"]
        ),
        BarcodeBundle(
            name: "unassigned",
            orderedReadIDs: ["u1", "u2", "shared"],
            previewLimit: 1_000,
            trimEntries: [trim("shared", mate: 0, 1, 1)],
            orientMap: ["u2": "-"],
            expectedReadCount: 3,
            expectedPreview: ["u1", "u2", "shared"]
        ),
    ]

    private func previewIDs(_ bundle: BarcodeBundle) -> [String] {
        Array(bundle.orderedReadIDs.prefix(bundle.previewLimit))
    }

    private func names(in url: URL) async throws -> [String] {
        var names: [String] = []
        for try await record in FASTQReader(validateSequence: false).records(from: url) {
            names.append(record.identifier)
        }
        return names
    }

    /// The one-pass plan of every bundle, writing into `folder`.
    private func onePassPlan(in folder: URL) throws -> DemultiplexingPipeline.VirtualRootRebuildPlan {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var plan = DemultiplexingPipeline.VirtualRootRebuildPlan()
        for bundle in Self.bundles {
            _ = plan.add(DemultiplexingPipeline.VirtualBarcodeRebuild(
                orderedReadIDs: bundle.orderedReadIDs,
                previewReadIDs: previewIDs(bundle),
                trimEntries: bundle.trimEntries,
                orientMap: bundle.orientMap,
                previewURL: folder.appendingPathComponent("\(bundle.name)-preview.fastq"),
                statisticsURL: folder.appendingPathComponent("\(bundle.name)-stats.fastq")
            ))
        }
        return plan
    }

    /// Runs the per-barcode reference for every bundle into `folder`.
    private func perBarcodeReference(
        _ pipeline: DemultiplexingPipeline,
        rootFASTQs: [URL],
        in folder: URL
    ) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for bundle in Self.bundles {
            try await pipeline.perBarcodeReferencePreview(
                fromRootFASTQs: rootFASTQs,
                orderedReadIDs: previewIDs(bundle),
                trimEntries: bundle.trimEntries,
                orientMap: bundle.orientMap,
                outputURL: folder.appendingPathComponent("\(bundle.name)-preview.fastq")
            )
            try await pipeline.perBarcodeReferenceStatistics(
                fromRootFASTQs: rootFASTQs,
                orderedReadIDs: bundle.orderedReadIDs,
                trimEntries: bundle.trimEntries,
                orientMap: bundle.orientMap,
                outputURL: folder.appendingPathComponent("\(bundle.name)-stats.fastq")
            )
        }
    }

    func testTheOnePassWritesWhatThePerBarcodeRebuildWrote() async throws {
        let pipeline = DemultiplexingPipeline()
        for multiFile in [true, false] {
            let shape = multiFile ? "multi-file root" : "single-file root"
            let rootFASTQs = try writeRoot(multiFile: multiFile)
            let referenceFolder = root.appendingPathComponent("reference-\(multiFile)", isDirectory: true)
            let onePassFolder = root.appendingPathComponent("one-pass-\(multiFile)", isDirectory: true)
            try await perBarcodeReference(pipeline, rootFASTQs: rootFASTQs, in: referenceFolder)
            let plan = try onePassPlan(in: onePassFolder)
            try await pipeline.rebuildVirtualBarcodeFiles(fromRootFASTQs: rootFASTQs, plan: plan)

            var referenceStatistics: [FASTQDatasetStatistics] = []
            for bundle in Self.bundles {
                let preview = "\(bundle.name)-preview.fastq"
                let stats = "\(bundle.name)-stats.fastq"
                let referencePreview = try Data(contentsOf: referenceFolder.appendingPathComponent(preview))
                let referenceStats = try Data(contentsOf: referenceFolder.appendingPathComponent(stats))
                XCTAssertEqual(try Data(contentsOf: onePassFolder.appendingPathComponent(preview)), referencePreview, "\(shape) \(bundle.name): the preview")
                XCTAssertEqual(try Data(contentsOf: onePassFolder.appendingPathComponent(stats)), referenceStats, "\(shape) \(bundle.name): the statistics FASTQ")
                let previewNames = try await names(in: onePassFolder.appendingPathComponent(preview))
                XCTAssertEqual(previewNames, bundle.expectedPreview, "\(shape) \(bundle.name): the preview's reads and order")
                referenceStatistics.append(try await FASTQReader(validateSequence: false)
                    .computeStatistics(from: referenceFolder.appendingPathComponent(stats), sampleLimit: 0).statistics)
            }
            // The one pass's statistics, computed as before, and its files deleted once read.
            let onePassStatistics = try await pipeline.virtualBarcodeStatistics(plan: plan)
            XCTAssertEqual(onePassStatistics, referenceStatistics, "\(shape): the cached statistics")
            XCTAssertEqual(onePassStatistics.map(\.readCount), Self.bundles.map(\.expectedReadCount), "\(shape): the counts, unassigned included")
            for bundle in Self.bundles {
                XCTAssertFalse(FileManager.default.fileExists(atPath: onePassFolder.appendingPathComponent("\(bundle.name)-stats.fastq").path))
            }
        }
    }

    func testTheOnePassReadsTheRootOnceWhateverTheNumberOfBundles() async throws {
        for multiFile in [true, false] {
            let shape = multiFile ? "multi-file root" : "single-file root"
            let rootFASTQs = try writeRoot(multiFile: multiFile)

            let onePass = RootReadCounter()
            let onePassPipeline = DemultiplexingPipeline(runner: .shared, rootRecordSource: onePass.source)
            let consumed = try await onePassPipeline.rebuildVirtualBarcodeFiles(
                fromRootFASTQs: rootFASTQs,
                plan: try onePassPlan(in: root.appendingPathComponent("count-one-pass-\(multiFile)", isDirectory: true))
            )
            XCTAssertEqual(consumed, Self.rootRecordCount, "\(shape): every root record once")
            XCTAssertEqual(onePass.records, Self.rootRecordCount, "\(shape): the reader read the root once")
            for url in rootFASTQs {
                XCTAssertEqual(onePass.opens(of: url), 1, "\(shape): \(url.lastPathComponent) is opened once")
            }

            let perBarcode = RootReadCounter()
            try await perBarcodeReference(
                DemultiplexingPipeline(runner: .shared, rootRecordSource: perBarcode.source),
                rootFASTQs: rootFASTQs,
                in: root.appendingPathComponent("count-reference-\(multiFile)", isDirectory: true)
            )
            // A statistics pass per bundle opens every root file, and each preview pass opens them again until it is complete.
            for url in rootFASTQs {
                XCTAssertGreaterThanOrEqual(perBarcode.opens(of: url), Self.bundles.count, "\(shape): the reference read the root once per bundle at least")
            }
            print("one-pass check (\(shape), \(Self.bundles.count) bundles): one pass opened \(rootFASTQs.map { onePass.opens(of: $0) }) and read \(onePass.records) records, the per-barcode rebuild opened \(rootFASTQs.map { perBarcode.opens(of: $0) }) and read \(perBarcode.records)")
        }
    }

    /// A virtual demultiplex of a two-chunk root with two barcodes and an
    /// unassigned read reads the root files once through the pipeline.
    func testAVirtualDemultiplexReadsItsRootFilesOnce() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
        let barcode1 = "ACGTTGCAAGTC"
        let barcode2 = "GGTACCTTAAGC"
        let insert = "GATTACAGATTACAGATTACAGATTACA"
        let bundle = root.appendingPathComponent("Project.lungfish/Imports/multi.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let first: [(name: String, sequence: String)] = [
            ("c0r1", barcode1 + insert), ("c0r2", barcode1 + insert), ("c0r3", barcode2 + insert), ("c0r4", "CCCCCCCCCCCC" + insert),
        ]
        let second: [(name: String, sequence: String)] = [
            ("c1r1", barcode2 + insert), ("c1r2", barcode1 + insert), ("c1r3", barcode2 + insert), ("c1r4", barcode1 + insert),
        ]
        let chunkURLs = [chunks.appendingPathComponent("run_0.fastq"), chunks.appendingPathComponent("run_1.fastq")]
        try Self.fastq(first).write(to: chunkURLs[0], atomically: true, encoding: .utf8)
        try Self.fastq(second).write(to: chunkURLs[1], atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)
        // The input the dashboard demultiplexes, every chunk joined.
        let joined = root.appendingPathComponent("Project.lungfish/joined.fastq")
        try Self.fastq(first + second).write(to: joined, atomically: true, encoding: .utf8)
        let kitCSV = root.appendingPathComponent("barcodes.csv")
        try "id,sequence\nBC01,\(barcode1)\nBC02,\(barcode2)\n".write(to: kitCSV, atomically: true, encoding: .utf8)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: kitCSV, name: "Custom")

        let counter = RootReadCounter()
        let pipeline = DemultiplexingPipeline(runner: .shared, rootRecordSource: counter.source)
        let output = bundle.appendingPathComponent("demux", isDirectory: true)
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: joined,
                sourceBundleURL: bundle,
                barcodeKit: kit,
                outputDirectory: output,
                barcodeLocation: .fivePrime,
                errorRate: 0.15,
                trimBarcodes: false,
                unassignedDisposition: .keep,
                engine: .cutadapt,
                rootBundleURL: bundle,
                rootFASTQFilename: "chunks/run_0.fastq",
                inputSequenceFormat: .fastq
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.barcodes.first { $0.barcodeID == "BC01" }?.readCount, 4)
        XCTAssertEqual(result.manifest.barcodes.first { $0.barcodeID == "BC02" }?.readCount, 3)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)
        XCTAssertEqual(result.manifest.inputReadCount, 8)
        XCTAssertEqual(counter.records, 8, "three virtual bundles, the root's 8 records read once")
        for url in chunkURLs {
            XCTAssertEqual(counter.opens(of: url), 1, "\(url.lastPathComponent) is opened once")
        }
    }
}
