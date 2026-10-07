// DemultiplexVirtualRootGroupedRebuildTests.swift - Virtual barcode bundles are rebuilt from their root in groups of eight
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 1z rebuilt every virtual barcode bundle's preview and statistics in
// one pass over the root. Its routing plan, the previews it held in memory
// and the statistics FASTQs it kept on disk all grew with the number of
// bundles (1z re-review SF1 and SF2). The pipeline now rebuilds the bundles
// in groups of at most eight, its maxConcurrentBundles in virtual mode, with
// one pass over the root files per group. The fixture holds twelve bundles,
// BC01 to BC11 and unassigned, so they fall in two groups, and three reads
// are listed by bundles of both groups. Every bundle's preview, statistics
// FASTQ and statistics must match the per-barcode reference kept in
// DemultiplexVirtualRootOnePassTests byte for byte. The root must be read
// ceil(12 / 8) = 2 times, and at most eight statistics FASTQs may be on disk
// at the end of each pass. Only the pipeline test runs tools, and it skips
// without cutadapt and seqkit.

import Foundation
import os
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Counts how often each root file is opened and how many records are read.
/// When the last root file's records have all been read, which ends a pass,
/// it runs `atEndOfPass` and keeps the count that returns.
private final class RootPassCounter: Sendable {
    private struct State {
        var opens: [String: Int] = [:]
        var records = 0
        var endOfPassCounts: [Int] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let lastRootFile: String
    private let atEndOfPass: @Sendable () -> Int

    init(lastRootFile: URL, atEndOfPass: @escaping @Sendable () -> Int) {
        self.lastRootFile = lastRootFile.standardizedFileURL.path
        self.atEndOfPass = atEndOfPass
    }

    var records: Int { state.withLock { $0.records } }
    /// What `atEndOfPass` returned at the end of each pass, in pass order.
    var endOfPassCounts: [Int] { state.withLock { $0.endOfPassCounts } }

    func opens(of url: URL) -> Int {
        let path = url.standardizedFileURL.path
        return state.withLock { $0.opens[path] ?? 0 }
    }

    /// The pipeline's root reader, counted.
    var source: VirtualRootRecordSource {
        { url in
            let path = url.standardizedFileURL.path
            self.state.withLock { $0.opens[path, default: 0] += 1 }
            let records = DemultiplexingPipeline.fileRootRecordSource(url)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await record in records {
                            self.state.withLock { $0.records += 1 }
                            continuation.yield(record)
                        }
                        if path == self.lastRootFile {
                            let count = self.atEndOfPass()
                            self.state.withLock { $0.endOfPassCounts.append(count) }
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

/// The statistics FASTQs the fixture's plan writes into `folder`, named `<bundle>-stats.fastq`.
private func statisticsFASTQs(in folder: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix("-stats.fastq") }.sorted().map { folder.appendingPathComponent($0) }
}

/// The statistics FASTQs a pipeline run writes into its work folder, named
/// `stats-<barcode>-<UUID>.fastq`, anywhere under `folder`.
private func pipelineStatisticsFASTQs(under folder: URL) -> [URL] {
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
    return files.compactMap { $0 as? URL }
        .filter { $0.lastPathComponent.hasPrefix("stats-") && $0.pathExtension == "fastq" }
}

/// Rebuilds `bundles` as the pipeline does. Each is added to a group of eight
/// as its task would end, and the last group is rebuilt after the last bundle.
/// - Returns: How many results each `add` returned, how many the last `flush`
///   returned, and every result in the order it came back.
private func rebuildInGroupsOfEight(
    _ bundles: [(name: String, rebuild: DemultiplexingPipeline.VirtualBarcodeRebuild)],
    pipeline: DemultiplexingPipeline,
    rootFASTQs: [URL]
) async throws -> (resultsPerAdd: [Int], lastGroup: Int, results: [(name: String, statistics: FASTQDatasetStatistics)]) {
    var group = DemultiplexingPipeline.VirtualRootRebuildGroup<(name: String, statistics: FASTQDatasetStatistics)>(
        pipeline: pipeline,
        rootFASTQs: rootFASTQs,
        capacity: 8
    )
    var resultsPerAdd: [Int] = []
    var results: [(name: String, statistics: FASTQDatasetStatistics)] = []
    for (name, rebuild) in bundles {
        let returned = try await group.add(rebuild) { (name, $0) }
        resultsPerAdd.append(returned.count)
        results += returned
    }
    let lastGroup = try await group.flush()
    return (resultsPerAdd, lastGroup.count, results + lastGroup)
}

final class DemultiplexVirtualRootGroupedRebuildTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-virtual-root-grouped-rebuild")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The root's records, as two chunks. `dup` repeats with three sequences,
    /// `p1` is a mate pair named the Illumina way and `q1` one named with /1
    /// and /2. `shared`, `crossed` and `twin` are listed by bundles of both
    /// groups, and `twin` by two bundles of the first group as well.
    private static let firstChunk: [(name: String, sequence: String)] = [
        ("a1", "ACGTACGTACGTAAAACCCC"),
        ("dup", "GATTACAGATTACAGATTAC"),
        ("b1", "TTTTGGGGCCCCAAAATTTT"),
        ("twin", "AGCTAGCTAGCTTTGGCCAA"),
        ("a2", "CCCCGGGGAAAATTTTACGT"),
        ("p1 1:N:0:ACGT", "AAAAACCCCCGGGGGTTTTT"),
        ("p1 2:N:0:ACGT", "TTTTTGGGGGCCCCCAAAAA"),
        ("c1", "CAGTCAGTCAGTCAGTCAGT"),
        ("d1", "GGGGAAAACCCCTTTTGGGG"),
        ("shared", "AACCGGTTAACCGGTTAACC"),
        ("e1", "TGCATGCATGCATGCATGCA"),
        ("f1", "ATATATATCGCGCGCGATAT"),
        ("u1", "ACACACACACGTGTGTGTGT"),
        ("g1", "CCGGAATTCCGGAATTCCGG"),
    ]
    private static let secondChunk: [(name: String, sequence: String)] = [
        ("dup", "CATCATCATCATCATCATCA"),
        ("h1", "GTCAGTCAGTCAGTCAGTCA"),
        ("q1/1", "ACGGTACCGTTAGCATGCAA"),
        ("q1/2", "TTGCATGCTAACGGTACCGT"),
        ("crossed", "GACTGACTGACTAAGGTTCC"),
        ("j1", "TCGATCGATCGAAATTGGCC"),
        ("a3", "TACGTACGTACGTACGTACG"),
        ("k1", "GGCCTTAAGGCCTTAAGGCC"),
        ("dup", "TGATGATGATGATGATGATG"),
        ("u2", "GTGTGTGTGTACACACACAC"),
        ("i1", "CTCTCTCTGAGAGAGACTCT"),
        ("j2", "AGAGAGAGTCTCTCTCAGAG"),
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
        /// 1,000 in the pipeline. A smaller limit makes the preview complete early.
        var previewLimit = 1_000
        var trimEntries: [DemultiplexingPipeline.DemuxTrimEntry] = []
        var orientMap: [String: String] = [:]
        /// How many records the statistics FASTQ holds, every root record of a read the bundle lists.
        let expectedReadCount: Int
        /// The names of the preview's records, in preview order.
        let expectedPreview: [String]

        var previewReadIDs: [String] { Array(orderedReadIDs.prefix(previewLimit)) }
    }

    private static func trim(_ readID: String, mate: Int, _ trim5p: Int, _ trim3p: Int) -> DemultiplexingPipeline.DemuxTrimEntry {
        DemultiplexingPipeline.DemuxTrimEntry(readID: readID, mate: mate, trim5p: trim5p, trim3p: trim3p, rootReadLength: nil)
    }

    /// The bundles in the order they are added, so BC01 to BC08 are the first
    /// group and BC09 to unassigned the second. BC01 has mate-specific trims, a
    /// trim listed twice and a trim for a read it does not list. BC02's preview
    /// completes at `twin` in the first chunk, and `dup` comes back twice after
    /// that. BC03 lists `twin` after `c1`, although the root holds it first.
    /// BC11 lists `ghost`, which the root does not hold, so its preview never
    /// completes. `shared`, `crossed` and `twin` carry different trims and
    /// orientations in each bundle that lists them.
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
            orderedReadIDs: ["dup", "twin", "b1"],
            previewLimit: 2,
            trimEntries: [trim("dup", mate: 0, 1, 1)],
            orientMap: ["dup": "-"],
            expectedReadCount: 5,
            expectedPreview: ["dup", "twin"]
        ),
        BarcodeBundle(
            name: "BC03",
            orderedReadIDs: ["c1", "twin"],
            trimEntries: [trim("twin", mate: 0, 2, 0)],
            orientMap: ["twin": "-"],
            expectedReadCount: 2,
            expectedPreview: ["c1", "twin"]
        ),
        BarcodeBundle(name: "BC04", orderedReadIDs: ["d1"], expectedReadCount: 1, expectedPreview: ["d1"]),
        BarcodeBundle(
            name: "BC05",
            orderedReadIDs: ["e1"],
            trimEntries: [trim("e1", mate: 0, 0, 4)],
            orientMap: ["e1": "-"],
            expectedReadCount: 1,
            expectedPreview: ["e1"]
        ),
        BarcodeBundle(name: "BC06", orderedReadIDs: ["f1"], expectedReadCount: 1, expectedPreview: ["f1"]),
        BarcodeBundle(
            name: "BC07",
            orderedReadIDs: ["g1"],
            trimEntries: [trim("g1", mate: 0, 3, 0)],
            expectedReadCount: 1,
            expectedPreview: ["g1"]
        ),
        BarcodeBundle(
            name: "BC08",
            orderedReadIDs: ["h1", "crossed"],
            trimEntries: [trim("crossed", mate: 0, 1, 2)],
            orientMap: ["crossed": "-"],
            expectedReadCount: 2,
            expectedPreview: ["h1", "crossed"]
        ),
        BarcodeBundle(
            name: "BC09",
            orderedReadIDs: ["q1", "i1"],
            trimEntries: [trim("q1", mate: 2, 0, 3), trim("q1", mate: 1, 2, 0)],
            orientMap: ["q1": "-"],
            expectedReadCount: 3,
            // A pair's read ID listed once previews its first mate. It kept
            // one record per read ID, the last mate seen, before A9.
            expectedPreview: ["q1/1", "i1"]
        ),
        BarcodeBundle(
            name: "BC10",
            orderedReadIDs: ["j1", "shared", "j2"],
            previewLimit: 2,
            trimEntries: [trim("shared", mate: 0, 3, 3)],
            orientMap: ["shared": "-"],
            expectedReadCount: 3,
            expectedPreview: ["j1", "shared"]
        ),
        BarcodeBundle(
            name: "BC11",
            orderedReadIDs: ["k1", "twin", "ghost"],
            trimEntries: [trim("twin", mate: 0, 0, 2)],
            orientMap: ["k1": "-"],
            expectedReadCount: 2,
            expectedPreview: ["k1", "twin"]
        ),
        BarcodeBundle(
            name: "unassigned",
            orderedReadIDs: ["u1", "u2", "crossed"],
            trimEntries: [trim("crossed", mate: 0, 2, 1)],
            orientMap: ["u2": "-"],
            expectedReadCount: 3,
            expectedPreview: ["u1", "u2", "crossed"]
        ),
    ]

    private func rebuild(_ bundle: BarcodeBundle, in folder: URL) -> DemultiplexingPipeline.VirtualBarcodeRebuild {
        DemultiplexingPipeline.VirtualBarcodeRebuild(
            orderedReadIDs: bundle.orderedReadIDs,
            previewReadIDs: bundle.previewReadIDs,
            trimEntries: bundle.trimEntries,
            orientMap: bundle.orientMap,
            previewURL: folder.appendingPathComponent("\(bundle.name)-preview.fastq"),
            statisticsURL: folder.appendingPathComponent("\(bundle.name)-stats.fastq")
        )
    }

    /// Runs the per-barcode reference for every bundle into `folder`.
    private func perBarcodeReference(rootFASTQs: [URL], in folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pipeline = DemultiplexingPipeline()
        for bundle in Self.bundles {
            try await pipeline.perBarcodeReferencePreview(
                fromRootFASTQs: rootFASTQs,
                orderedReadIDs: bundle.previewReadIDs,
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

    private func names(in url: URL) async throws -> [String] {
        var names: [String] = []
        for try await record in FASTQReader(validateSequence: false).records(from: url) {
            names.append(record.identifier)
        }
        return names
    }

    func testGroupsOfEightWriteWhatThePerBarcodeRebuildWrote() async throws {
        for multiFile in [true, false] {
            let shape = multiFile ? "multi-file root" : "single-file root"
            let rootFASTQs = try writeRoot(multiFile: multiFile)
            let referenceFolder = root.appendingPathComponent("reference-\(multiFile)", isDirectory: true)
            try await perBarcodeReference(rootFASTQs: rootFASTQs, in: referenceFolder)

            let folder = root.appendingPathComponent("grouped-\(multiFile)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // At the end of each pass, count the statistics FASTQs on disk and keep a
            // hard link to each, because the group deletes them once it has read them.
            let counter = RootPassCounter(lastRootFile: rootFASTQs[rootFASTQs.count - 1]) {
                let files = statisticsFASTQs(in: folder)
                for file in files {
                    try? FileManager.default.linkItem(at: file, to: file.appendingPathExtension("kept"))
                }
                return files.count
            }
            let grouped = try await rebuildInGroupsOfEight(
                Self.bundles.map { ($0.name, rebuild($0, in: folder)) },
                pipeline: DemultiplexingPipeline(runner: .shared, rootRecordSource: counter.source),
                rootFASTQs: rootFASTQs
            )

            // Twelve bundles are two groups, eight and then four, each rebuilt in one pass.
            XCTAssertEqual(grouped.resultsPerAdd, [0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0], "\(shape): a group is rebuilt as soon as it holds eight bundles")
            XCTAssertEqual(grouped.lastGroup, 4, "\(shape): the last four bundles are rebuilt after the last one is added")
            XCTAssertEqual(grouped.results.map { $0.name }, Self.bundles.map(\.name), "\(shape): every bundle once, in the order added")
            for url in rootFASTQs {
                XCTAssertEqual(counter.opens(of: url), 2, "\(shape): \(url.lastPathComponent) is read once per group, ceil(12 / 8) = 2 times")
            }
            XCTAssertEqual(counter.records, 2 * Self.rootRecordCount, "\(shape): every root record once per pass")
            XCTAssertEqual(counter.endOfPassCounts, [8, 4], "\(shape): the statistics FASTQs on disk at the end of each pass")
            XCTAssertTrue(counter.endOfPassCounts.allSatisfy { $0 <= 8 }, "\(shape): never more than eight statistics FASTQs on disk")
            XCTAssertEqual(statisticsFASTQs(in: folder), [], "\(shape): every statistics FASTQ is deleted once read")

            for (bundle, result) in zip(Self.bundles, grouped.results) {
                let preview = "\(bundle.name)-preview.fastq"
                let stats = "\(bundle.name)-stats.fastq"
                XCTAssertEqual(
                    try Data(contentsOf: folder.appendingPathComponent(preview)),
                    try Data(contentsOf: referenceFolder.appendingPathComponent(preview)),
                    "\(shape) \(bundle.name): the preview"
                )
                XCTAssertEqual(
                    try Data(contentsOf: folder.appendingPathComponent(stats).appendingPathExtension("kept")),
                    try Data(contentsOf: referenceFolder.appendingPathComponent(stats)),
                    "\(shape) \(bundle.name): the statistics FASTQ"
                )
                let previewNames = try await names(in: folder.appendingPathComponent(preview))
                XCTAssertEqual(previewNames, bundle.expectedPreview, "\(shape) \(bundle.name): the preview's reads and order")
                let referenceStatistics = try await FASTQReader(validateSequence: false)
                    .computeStatistics(from: referenceFolder.appendingPathComponent(stats), sampleLimit: 0).statistics
                XCTAssertEqual(result.statistics, referenceStatistics, "\(shape) \(bundle.name): the cached statistics")
                XCTAssertEqual(result.statistics.readCount, bundle.expectedReadCount, "\(shape) \(bundle.name): the count")
            }
        }
    }

    /// Eleven barcodes, 12-mers at least seven mismatches apart.
    private static let barcodes: [(id: String, sequence: String)] = [
        ("BC01", "TTCGTGACAGAC"), ("BC02", "GACTCAAGCCAA"), ("BC03", "TTGCTGGATTGT"), ("BC04", "TAGCATGTCGGC"),
        ("BC05", "TGCTATCATCTC"), ("BC06", "ACGTAAGGCGCA"), ("BC07", "CACAGTGCCAAG"), ("BC08", "GCTACGCTCCAT"),
        ("BC09", "AGTCTGCCTCCT"), ("BC10", "TGAGGTCCAGTG"), ("BC11", "GGACCGTATGCA"),
    ]

    /// A virtual demultiplex of a two-chunk root into eleven barcodes and
    /// unassigned rebuilds its twelve bundles in two groups through the pipeline.
    func testAVirtualDemultiplexOfTwelveBundlesReadsItsRootOncePerGroupOfEight() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Imports/multi.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        // Each chunk holds one read per barcode and one read with no barcode.
        let insert = "GATTACAGATTACAGATTACAGATTACA"
        func chunk(_ index: Int) -> [(name: String, sequence: String)] {
            Self.barcodes.map { (name: "c\(index)_\($0.id)", sequence: $0.sequence + insert) }
                + [(name: "c\(index)_none", sequence: "CCCCCCCCCCCC" + insert)]
        }
        let chunkURLs = [chunks.appendingPathComponent("run_0.fastq"), chunks.appendingPathComponent("run_1.fastq")]
        try Self.fastq(chunk(0)).write(to: chunkURLs[0], atomically: true, encoding: .utf8)
        try Self.fastq(chunk(1)).write(to: chunkURLs[1], atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)
        // The input the dashboard demultiplexes, every chunk joined.
        let joined = project.appendingPathComponent("joined.fastq")
        try Self.fastq(chunk(0) + chunk(1)).write(to: joined, atomically: true, encoding: .utf8)
        let kitCSV = root.appendingPathComponent("barcodes.csv")
        try ("id,sequence\n" + Self.barcodes.map { "\($0.id),\($0.sequence)\n" }.joined())
            .write(to: kitCSV, atomically: true, encoding: .utf8)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: kitCSV, name: "Custom")

        // The pipeline's statistics FASTQs live in its work folder under the project.
        let counter = RootPassCounter(lastRootFile: chunkURLs[1]) {
            pipelineStatisticsFASTQs(under: project).count
        }
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

        XCTAssertEqual(result.manifest.barcodes.map(\.barcodeID), Self.barcodes.map { $0.id })
        for barcode in result.manifest.barcodes {
            XCTAssertEqual(barcode.readCount, 2, "\(barcode.barcodeID) holds its read of each chunk")
        }
        XCTAssertEqual(result.manifest.unassigned.readCount, 2)
        XCTAssertEqual(result.manifest.inputReadCount, 24)
        // Twelve bundles, so ceil(12 / 8) = 2 passes over the root, for eight bundles and then four.
        for url in chunkURLs {
            XCTAssertEqual(counter.opens(of: url), 2, "\(url.lastPathComponent) is read once per group")
        }
        XCTAssertEqual(counter.records, 2 * 24, "the root's 24 records once per pass")
        XCTAssertEqual(counter.endOfPassCounts, [8, 4], "the statistics FASTQs on disk at the end of each pass")
        XCTAssertEqual(pipelineStatisticsFASTQs(under: project), [], "no statistics FASTQ is left behind")
        // The bundles of both groups have their previews.
        for id in Self.barcodes.map({ $0.id }) + ["unassigned"] {
            let bundleURL = output.appendingPathComponent("\(id).\(FASTQBundle.directoryExtension)", isDirectory: true)
            let listed = try String(contentsOf: bundleURL.appendingPathComponent("read-ids.txt"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let previewNames = try await names(in: bundleURL.appendingPathComponent("preview.fastq"))
            XCTAssertEqual(previewNames, listed, "\(id): the preview holds the reads the bundle lists")
            XCTAssertEqual(listed.count, 2, "\(id): one read of each chunk")
        }
    }
}
