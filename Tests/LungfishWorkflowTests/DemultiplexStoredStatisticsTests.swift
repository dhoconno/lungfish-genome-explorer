// DemultiplexStoredStatisticsTests.swift - A demultiplexed bundle stores the statistics of the reads it holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// Each demultiplexing route stores statistics on every bundle it makes, and the viewer shows them as measured. The
/// exact and exact-bare routes stored 0 for mean Q, Q20, Q30 and GC with an empty score histogram, the exact route's
/// unassigned bundle stored median 0 and N50 0 as well, and the exact route took the upper middle length as the median
/// of an even count. Nobody counted those numbers (Phase 3.0 lane DEMUX-STATS, walk WF-8b). Each test demultiplexes a
/// few reads with scores that vary and checks every stored field against a fresh `FASTQStatisticsCollector` pass over
/// the reads the bundle holds. The cutadapt route needs real tools and has its own conformance class.
final class DemultiplexStoredStatisticsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-stored-statistics")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Exact route (asymmetric kit with sample assignments)

    private static let forwardA = "ACGTTCAGGATCCTAGCATGCGAT"
    private static let reverseA = "TTGACCGGTAACGTCAGTCAGGCA"
    private static let forwardB = "GATCCAGTTGCAAGTCGGATCTAG"
    private static let reverseB = "CCTAGGTTCAAGCTGACTGGATCC"

    func testTheExactRouteStoresTheCountedStatisticsOfEverySampleAndTheUnassignedReads() async throws {
        let rc = PlatformAdapters.reverseComplement
        var reads: [(id: String, sequence: String)] = []
        // Sample A holds four reads of four lengths, so its median is the second length, not the third.
        for (index, insert) in [40, 50, 60, 70].enumerated() {
            reads.append(("a\(index)", Self.forwardA + Self.bases(insert, seed: index) + rc(Self.reverseA)))
        }
        for (index, insert) in [45, 55, 65].enumerated() {
            reads.append(("b\(index)", Self.forwardB + Self.bases(insert, seed: 10 + index) + rc(Self.reverseB)))
        }
        for (index, length) in [90, 96, 102].enumerated() {
            reads.append(("u\(index)", Self.bases(length, seed: 20 + index)))
        }
        let rootBundle = try writeRootBundle(named: "exact", files: ["reads.fastq": reads])
        let kit = BarcodeKitDefinition(
            id: "stored-statistics-asymmetric",
            displayName: "Stored statistics asymmetric",
            vendor: "pacbio",
            platform: .pacbio,
            kitType: .custom,
            isDualIndexed: true,
            pairingMode: .fixedDual,
            barcodes: [
                BarcodeEntry(id: "bcA", i7Sequence: Self.forwardA, i5Sequence: Self.reverseA),
                BarcodeEntry(id: "bcB", i7Sequence: Self.forwardB, i5Sequence: Self.reverseB),
            ]
        )
        let assignments = [
            FASTQSampleBarcodeAssignment(
                sampleID: "SampleA", sampleName: "Sample A", forwardBarcodeID: "bcA", forwardSequence: Self.forwardA,
                reverseBarcodeID: nil, reverseSequence: Self.reverseA, metadata: [:]
            ),
            FASTQSampleBarcodeAssignment(
                sampleID: "SampleB", sampleName: "Sample B", forwardBarcodeID: "bcB", forwardSequence: Self.forwardB,
                reverseBarcodeID: nil, reverseSequence: Self.reverseB, metadata: [:]
            ),
        ]

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: rootBundle.appendingPathComponent("reads.fastq"),
                sourceBundleURL: rootBundle,
                barcodeKit: kit,
                outputDirectory: root.appendingPathComponent("exact-out", isDirectory: true),
                symmetryMode: .asymmetric,
                sampleAssignments: assignments,
                rootBundleURL: rootBundle,
                rootFASTQFilename: "reads.fastq",
                inputSequenceFormat: .fastq,
                minimumInsert: 20
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.outputBundleURLs.count, 2, "one bundle for each sample")
        let unassigned = try XCTUnwrap(result.unassignedBundleURL, "the unassigned reads are kept")
        try await assertEveryBundleStoresItsCountedStatistics(
            result.outputBundleURLs + [unassigned],
            rootFiles: [rootBundle.appendingPathComponent("reads.fastq")]
        )
    }

    // MARK: - Exact-bare route

    private static let bareBC01 = "ACGGTCTAGCAT"
    private static let bareBC02 = "TGCATCCGGATA"

    func testTheExactBareRouteStoresTheCountedStatisticsOfEveryBarcodeAndTheUnassignedReads() async throws {
        let rootBundle = try writeRootBundle(named: "bare", files: ["reads.fastq": Self.bareReads(prefix: "r")])
        let result = try await DemultiplexingPipeline().run(
            config: try bareConfig(rootBundle: rootBundle, rootFASTQFilename: "reads.fastq", output: "bare-out", threads: 1),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.outputBundleURLs.count, 2, "one bundle for each barcode")
        let unassigned = try XCTUnwrap(result.unassignedBundleURL, "the unassigned reads are kept")
        try await assertEveryBundleStoresItsCountedStatistics(
            result.outputBundleURLs + [unassigned],
            rootFiles: [rootBundle.appendingPathComponent("reads.fastq")]
        )
    }

    /// A root of several files is read by one worker a file, and the workers' counts are joined in file order.
    func testTheExactBareRouteJoinsTheCountedStatisticsOfEveryFileOfAMultiFileRoot() async throws {
        let rootBundle = try writeRootBundle(named: "bare-chunks", files: [
            "chunks/run_0.fastq": Self.bareReads(prefix: "c0-"),
            "chunks/run_1.fastq": Self.bareReads(prefix: "c1-", extraLength: 7),
        ])
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: rootBundle)

        let result = try await DemultiplexingPipeline().run(
            config: try bareConfig(
                rootBundle: rootBundle, rootFASTQFilename: "chunks/run_0.fastq", output: "bare-chunks-out", threads: 2
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.outputBundleURLs.count, 2, "one bundle for each barcode")
        let unassigned = try XCTUnwrap(result.unassignedBundleURL, "the unassigned reads are kept")
        try await assertEveryBundleStoresItsCountedStatistics(
            result.outputBundleURLs + [unassigned],
            rootFiles: [
                rootBundle.appendingPathComponent("chunks/run_0.fastq"),
                rootBundle.appendingPathComponent("chunks/run_1.fastq"),
            ]
        )
    }

    private func bareConfig(
        rootBundle: URL,
        rootFASTQFilename: String,
        output: String,
        threads: Int
    ) throws -> DemultiplexConfig {
        let kitCSV = root.appendingPathComponent("\(output)-kit.csv")
        try "id,sequence\nBC01,\(Self.bareBC01)\nBC02,\(Self.bareBC02)\n"
            .write(to: kitCSV, atomically: true, encoding: .utf8)
        return DemultiplexConfig(
            inputURL: rootBundle.appendingPathComponent(rootFASTQFilename),
            sourceBundleURL: rootBundle,
            barcodeKit: try BarcodeKitRegistry.loadCustomKit(from: kitCSV, name: "kit"),
            outputDirectory: root.appendingPathComponent(output, isDirectory: true),
            threads: threads,
            engine: .exactBareBarcode,
            rootBundleURL: rootBundle,
            rootFASTQFilename: rootFASTQFilename,
            inputSequenceFormat: .fastq
        )
    }

    /// Four BC01 reads, three BC02 reads and three reads with no barcode, each barcode at the 5' end.
    private static func bareReads(prefix: String, extraLength: Int = 0) -> [(id: String, sequence: String)] {
        var reads: [(id: String, sequence: String)] = []
        for (index, insert) in [30, 41, 52, 63].enumerated() {
            reads.append(("\(prefix)bc01-\(index)", bareBC01 + bases(insert + extraLength, seed: 30 + index)))
        }
        for (index, insert) in [35, 46, 57].enumerated() {
            reads.append(("\(prefix)bc02-\(index)", bareBC02 + bases(insert + extraLength, seed: 40 + index)))
        }
        for (index, length) in [44, 55, 66].enumerated() {
            reads.append(("\(prefix)none-\(index)", bases(length + extraLength, seed: 50 + index)))
        }
        return reads
    }

    // MARK: - ONT reads with PacBio barcode pairs, materialized per sample

    func testTheONTPacBioMaterializerStoresTheCountedStatisticsOfEverySampleItWrites() async throws {
        let rc = PlatformAdapters.reverseComplement
        let forward = "CACATATCAGAGTGCG"  // BC1001
        let reverse = "CTATACATAGTGATGT"  // BC1021
        let input = root.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        var reads: [(id: String, sequence: String)] = []
        for (index, insert) in [1_200, 1_300, 1_400, 1_500].enumerated() {
            reads.append((
                "read-\(index)",
                Self.bases(60, seed: 60 + index) + forward + Self.bases(insert, seed: 70 + index) + rc(reverse)
                    + Self.bases(60, seed: 80 + index)
            ))
        }
        reads.append(("off-target", Self.bases(1_400, seed: 90)))
        try Self.fastq(Array(reads.prefix(3)))
            .write(to: input.appendingPathComponent("chunk-1.fastq"), atomically: true, encoding: .utf8)
        try Self.fastq(Array(reads.dropFirst(3)))
            .write(to: input.appendingPathComponent("chunk-2.fastq"), atomically: true, encoding: .utf8)
        let sheet = root.appendingPathComponent("samples.barcodes.csv")
        try "S1,BC1001,BC1021\n".write(to: sheet, atomically: true, encoding: .utf8)

        let result = try await ONTPacBioBarcodeDemuxMaterializer().run(
            ONTPacBioBarcodeDemuxMaterializationRequest(
                inputURL: input,
                barcodeDefinitionsURL: sheet,
                outputDirectory: root.appendingPathComponent("pacbio-out", isDirectory: true),
                force: true,
                threads: 1,
                chunkJobs: 2,
                maxReadsPerSlice: 0
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.assignedReadCount, 4)
        let bundle = try XCTUnwrap(result.outputBundleURLs.first)
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle))
        let measured = try await FASTQReader(validateSequence: false).computeStatistics(from: payload, sampleLimit: 0)
        DemultiplexStoredStatisticsAssertions.assertStored(
            manifest.cachedStatistics, equals: measured.statistics, bundle.lastPathComponent
        )
    }

    // MARK: - Helpers

    /// Checks that each bundle's derived manifest stores what a fresh collector pass counts over the reads the bundle
    /// lists, read from the root files in order.
    private func assertEveryBundleStoresItsCountedStatistics(
        _ bundles: [URL],
        rootFiles: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for bundle in bundles {
            let manifest = try XCTUnwrap(
                FASTQBundle.loadDerivedManifest(in: bundle),
                "\(bundle.lastPathComponent) has a derived manifest", file: file, line: line
            )
            let measured = try await Self.measure(readsListedIn: bundle, from: rootFiles)
            DemultiplexStoredStatisticsAssertions.assertStored(
                manifest.cachedStatistics, equals: measured, bundle.lastPathComponent, file: file, line: line
            )
        }
    }

    static func measure(readsListedIn bundle: URL, from rootFiles: [URL]) async throws -> FASTQDatasetStatistics {
        let listed = Set(
            try String(contentsOf: bundle.appendingPathComponent("read-ids.txt"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        )
        let collector = FASTQStatisticsCollector()
        let reader = FASTQReader(validateSequence: false)
        for file in rootFiles {
            for try await record in reader.records(from: file) where listed.contains(record.identifier) {
                collector.process(record)
            }
        }
        return collector.finalize()
    }

    private func writeRootBundle(named name: String, files: [String: [(id: String, sequence: String)]]) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        for (relativePath, reads) in files {
            let url = bundle.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Self.fastq(reads).write(to: url, atomically: true, encoding: .utf8)
        }
        return bundle
    }

    /// FASTQ text whose scores run through Q2, Q10, Q20, Q30 and Q40 at a different phase in every read, so mean Q,
    /// Q20 and Q30 are neither 0 nor 100.
    static func fastq(_ reads: [(id: String, sequence: String)]) -> String {
        let symbols = Array("#+5?I")
        return reads.enumerated().map { readIndex, read in
            let quality = String((0..<read.sequence.count).map { symbols[($0 * 3 + readIndex) % symbols.count] })
            return "@\(read.id)\n\(read.sequence)\n+\n\(quality)\n"
        }.joined()
    }

    /// Bases from a fixed generator, so a run is reproducible and GC sits away from 0 and 1.
    static func bases(_ length: Int, seed: Int) -> String {
        var state = UInt64(seed) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let alphabet = Array("ACGT")
        return String((0..<length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return alphabet[Int((state >> 33) % 4)]
        })
    }
}

/// The comparison every demultiplexing route's stored statistics must pass.
enum DemultiplexStoredStatisticsAssertions {
    static func assertStored(
        _ stored: FASTQDatasetStatistics,
        equals measured: FASTQDatasetStatistics,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(measured.readCount, 0, "\(label) holds reads", file: file, line: line)
        XCTAssertEqual(stored.readCount, measured.readCount, "\(label) read count", file: file, line: line)
        XCTAssertEqual(stored.baseCount, measured.baseCount, "\(label) base count", file: file, line: line)
        XCTAssertEqual(stored.minReadLength, measured.minReadLength, "\(label) min length", file: file, line: line)
        XCTAssertEqual(stored.maxReadLength, measured.maxReadLength, "\(label) max length", file: file, line: line)
        XCTAssertEqual(stored.medianReadLength, measured.medianReadLength, "\(label) median", file: file, line: line)
        XCTAssertEqual(stored.n50ReadLength, measured.n50ReadLength, "\(label) N50", file: file, line: line)
        XCTAssertEqual(
            stored.meanReadLength, measured.meanReadLength, accuracy: 1e-9, "\(label) mean length", file: file, line: line
        )
        XCTAssertEqual(stored.meanQuality, measured.meanQuality, accuracy: 1e-9, "\(label) mean Q", file: file, line: line)
        XCTAssertEqual(stored.q20Percentage, measured.q20Percentage, accuracy: 1e-9, "\(label) Q20", file: file, line: line)
        XCTAssertEqual(stored.q30Percentage, measured.q30Percentage, accuracy: 1e-9, "\(label) Q30", file: file, line: line)
        XCTAssertEqual(stored.gcContent, measured.gcContent, accuracy: 1e-12, "\(label) GC", file: file, line: line)
        XCTAssertEqual(
            stored.readLengthHistogram, measured.readLengthHistogram, "\(label) length histogram", file: file, line: line
        )
        XCTAssertEqual(
            stored.qualityScoreHistogram, measured.qualityScoreHistogram, "\(label) score histogram", file: file, line: line
        )
        XCTAssertEqual(
            stored.perPositionQuality, measured.perPositionQuality, "\(label) per-position scores", file: file, line: line
        )
    }
}
