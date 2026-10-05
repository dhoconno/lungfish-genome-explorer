// GenotypingInputReadSetTests.swift - Amplicon genotyping reads every read of a bundle, in the right roles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `fastq genotype` and `fastq genotype-cohort` resolve each input to the
// FASTQ file one sample is read from. That resolution used to take the first
// physical file of a bundle, so a paired derivative (L5b) was genotyped from
// R1 alone, a merge derivative (L5c) from its merged reads alone, a repair
// derivative (L5d) from R1 alone, and a virtual derivative (L6) from its
// 1,000-read preview. Illumina inputs now reach the pair merger as one
// stream holding every read, pairs adjacent and single reads after them
// (docs/contracts/READ-PAIRING.md, Phase 1.5 lane A6b).

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class GenotypingInputReadSetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotyping-input-read-sets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The sample inputs the Illumina path (and the ONT sample-bundle path)
    /// builds for `bundles`, in a fresh staging folder.
    private func sampleInputs(_ bundles: [URL]) async throws -> [ONTBarcodeDemuxGenotypingPipeline.IlluminaSampleInput] {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return try await ONTBarcodeDemuxGenotypingPipeline
            .resolveIlluminaSampleInputsForTesting(from: bundles, stagingDirectory: staging)
    }

    /// The record names of the one file the run reads for `bundle`.
    private func readsOfOneSample(_ bundle: URL) async throws -> [String] {
        let samples = try await sampleInputs([bundle])
        XCTAssertEqual(samples.count, 1)
        return try ReadSetFixtures.readNames(in: try XCTUnwrap(samples.first).fastqURL)
    }

    // MARK: - Derived bundles: every read, pairs adjacent

    /// L5b. Before: R1 only, `p1/1 p2/1`.
    func testAPairedDerivativeReachesTheMergerAsBothMatesInterleavedByName() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let names = try await readsOfOneSample(fixtures.pairedDerivative)
        XCTAssertEqual(names, ["p1/1", "p1/2", "p2/1", "p2/2"])
    }

    /// L5c. Before: the merged reads only, `x1 x2 x3`, and the unmerged pair was lost.
    func testAMergeDerivativeReachesTheMergerWithItsPairAndItsMergedReads() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let names = try await readsOfOneSample(fixtures.mergeDerivative)
        XCTAssertEqual(names, ["u1/1", "u1/2", "x1", "x2", "x3"])
    }

    /// L5d. Before: R1 only, `r1/1 r2/1`, and R2 and the orphan were lost.
    func testARepairDerivativeReachesTheMergerWithItsPairsAndItsOrphan() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let names = try await readsOfOneSample(fixtures.repairDerivative)
        XCTAssertEqual(names, ["r1/1", "r1/2", "r2/1", "r2/2", "o1"])
    }

    // MARK: - One-file bundles keep their file

    /// L1, L2, L3 and L5a hold one file, which the run reads in place as it
    /// always did. The `genotype` golden is an L2 cohort.
    func testABundleOfOneFileIsReadInPlace() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let cases: [(URL, String, [String])] = [
            (fixtures.singleRoot, "single.fastq", ["s1", "s2", "s3"]),
            (fixtures.interleavedRoot, "reads.fastq", ["i1/1", "i1/2", "i2/1", "i2/2"]),
            (fixtures.mixedRoot, "reads.fastq", ["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"]),
            (fixtures.fullDerivative, "reads.fastq", ["g1", "g2"]),
        ]
        for (bundle, filename, names) in cases {
            let samples = try await sampleInputs([bundle])
            let sample = try XCTUnwrap(samples.first, bundle.lastPathComponent)
            XCTAssertEqual(sample.fastqURL, bundle.appendingPathComponent(filename).standardizedFileURL, bundle.lastPathComponent)
            XCTAssertEqual(sample.sourceURL, bundle.standardizedFileURL, bundle.lastPathComponent)
            XCTAssertEqual(try ReadSetFixtures.readNames(in: sample.fastqURL), names, bundle.lastPathComponent)
        }
    }

    // MARK: - ONT sample bundles of several files

    /// Final review A, S2. An ONT import of a barcode with several files is a
    /// chunked root. Genotyped as ONT sample bundles, each bundle is one
    /// sample named for the bundle, holding every chunk joined in import
    /// order, and the join is a `cat` provenance step whose inputs are the
    /// chunks. Two or more such bundles used to stop the run with a message
    /// that told an ONT user to import R1 and R2 reads with an Illumina recipe.
    func testEachONTChunkedRootIsOneSampleOfEveryChunkJoinedInImportOrder() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        let staging = root.appendingPathComponent("staging-ont", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bundles = [fixtures.nanoporeChunkedRoot, fixtures.chunkedRoot]
        let samples = try await ONTBarcodeDemuxGenotypingPipeline.resolveIlluminaSampleInputsForTesting(
            from: bundles,
            stagingDirectory: staging,
            readType: .ont
        )

        XCTAssertEqual(samples.map(\.sampleID), ["nanopore", "chunked"])
        XCTAssertEqual(samples.map(\.sourceURL), bundles.map(\.standardizedFileURL))
        let expected: [(reads: [String], chunks: [String])] = [
            (["o-a", "o-b", "o-c"], ["x_1.fastq", "x_2.fastq"]),
            (["c1", "c2", "c3"], ["run_0.fastq", "run_1.fastq"]),
        ]
        for (sample, expected) in zip(samples, expected) {
            XCTAssertEqual(try ReadSetFixtures.readNames(in: sample.fastqURL), expected.reads, sample.sampleID)
            XCTAssertEqual(sample.readCount, expected.reads.count, sample.sampleID)
            let steps = try XCTUnwrap(sample.inputReads, sample.sampleID).provenanceSteps(workflowVersion: "test")
            XCTAssertEqual(steps.map(\.toolName), [SequenceInputConcatenation.toolName], sample.sampleID)
            XCTAssertEqual(steps.first?.inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, expected.chunks, sample.sampleID)
            XCTAssertEqual(steps.first?.outputs.map(\.path), [sample.fastqURL.path], sample.sampleID)
        }
    }

    /// The chunks of an Illumina chunked root may be R1 and R2, so Illumina
    /// genotyping still refuses one rather than join its mates end to end.
    func testAnIlluminaChunkedRootIsStillRefused() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        do {
            _ = try await sampleInputs([fixtures.chunkedRoot])
            XCTFail("an Illumina chunked root must be refused")
        } catch let error as ONTBarcodeDemuxGenotypingError {
            XCTAssertEqual(error, .unsupportedIlluminaInput(fixtures.chunkedRoot.standardizedFileURL))
        }
    }

    // MARK: - Virtual bundles are materialized (seqkit)

    /// L6. Before: the preview, `f1` alone. The subset lists fragments f1 and
    /// f3, so the run reads both mates of each.
    func testAVirtualSubsetOfAnInterleavedRootIsMaterializedNotReadFromItsPreview() async throws {
        try await GenotypingVirtualInputFixtures.requireSeqkit()
        let subset = try GenotypingVirtualInputFixtures.makeIlluminaSubset(in: root)
        let names = try await readsOfOneSample(subset.bundle)
        XCTAssertEqual(names, ["f1 1:N:0:1", "f1 2:N:0:1", "f3 1:N:0:1", "f3 2:N:0:1"])
        XCTAssertNotEqual(names, subset.previewReads)
    }

    /// A demultiplexed ONT barcode given to the ONT sample-bundle path.
    /// Before: the preview, `r2 r3`.
    func testAVirtualDemultiplexedONTBarcodeIsMaterializedNotReadFromItsPreview() async throws {
        try await GenotypingVirtualInputFixtures.requireSeqkit()
        let barcode = try GenotypingVirtualInputFixtures.makeONTDemuxedBarcode(in: root)
        let names = try await readsOfOneSample(barcode.barcodeBundle)
        XCTAssertEqual(names, barcode.barcodeReads)
    }
}

/// Virtual bundles a genotyping run can be given, with read-ID lists that
/// name records the way `seqkit grep -f` matches them (the first word of a
/// header, which both mates of a Casava pair share).
enum GenotypingVirtualInputFixtures {
    static let previewFilename = "preview.fastq"

    static func record(_ header: String, _ sequence: String) -> String {
        "@\(header)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    static func requireSeqkit() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
    }

    struct ONTBarcode {
        let projectURL: URL
        let rootBundle: URL
        let barcodeBundle: URL
        /// The reads the barcode's list names, in root order.
        let barcodeReads: [String]
        /// The reads of its preview.
        let previewReads: [String]
    }

    struct IlluminaSubset {
        let projectURL: URL
        let rootBundle: URL
        let bundle: URL
        let previewReads: [String]
    }

    /// An ONT root of reads r1 to r10 recording the Oxford Nanopore platform,
    /// and a demultiplexed barcode `barcode01` whose list names r2, r3, r5,
    /// r7, r8 and r9, with the preview of r2 and r3 the demultiplexer writes.
    static func makeONTDemuxedBarcode(in directory: URL, sequence: String = "ACGTACGT") throws -> ONTBarcode {
        let fm = FileManager.default
        let project = directory.appendingPathComponent("ONT Barcodes.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let rootBundle = imports.appendingPathComponent("ont-run.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFile = rootBundle.appendingPathComponent("reads.fastq")
        let all = (1...10).map { "r\($0)" }
        try all.map { record($0, sequence) }.joined().write(to: rootFile, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore), for: rootFile)

        let barcodeReads = ["r2", "r3", "r5", "r7", "r8", "r9"]
        let previewReads = ["r2", "r3"]
        let demuxFolder = imports.appendingPathComponent("ont-run-demux", isDirectory: true)
        let barcodeBundle = demuxFolder.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: barcodeBundle, withIntermediateDirectories: true)
        try (barcodeReads.joined(separator: "\n") + "\n")
            .write(to: barcodeBundle.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try previewReads.map { record($0, sequence) }.joined()
            .write(to: barcodeBundle.appendingPathComponent(previewFilename), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .demultiplex)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "barcode01",
                parentBundleRelativePath: "@/Imports/ont-run.lungfishfastq",
                rootBundleRelativePath: "@/Imports/ont-run.lungfishfastq",
                rootFASTQFilename: "reads.fastq",
                payload: .demuxedVirtual(
                    barcodeID: "barcode01",
                    readIDListFilename: "read-ids.txt",
                    previewFilename: previewFilename
                ),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: barcodeReads.count, baseCount: Int64(barcodeReads.count * sequence.count)),
                pairingMode: .singleEnd
            ),
            in: barcodeBundle
        )
        return ONTBarcode(
            projectURL: project,
            rootBundle: rootBundle.standardizedFileURL,
            barcodeBundle: barcodeBundle.standardizedFileURL,
            barcodeReads: barcodeReads,
            previewReads: previewReads
        )
    }

    /// An ONT root holding `reads` and a virtual length-filter subset of it
    /// whose list names `listed`, with a preview of `preview`, the input a
    /// demultiplexing materializer can be given.
    static func makeONTSubset(
        in directory: URL,
        reads: [(id: String, sequence: String)],
        listed: [String],
        preview: [String]
    ) throws -> URL {
        let fm = FileManager.default
        let imports = directory
            .appendingPathComponent("ONT Subset.lungfish", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
        let rootBundle = imports.appendingPathComponent("ont-reads.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFile = rootBundle.appendingPathComponent("reads.fastq")
        try reads.map { record($0.id, $0.sequence) }.joined().write(to: rootFile, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore), for: rootFile)

        let sequences = Dictionary(uniqueKeysWithValues: reads.map { ($0.id, $0.sequence) })
        let bundle = imports.appendingPathComponent("ont-reads-subset.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try (listed.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try preview.map { record($0, sequences[$0] ?? "ACGT") }.joined()
            .write(to: bundle.appendingPathComponent(previewFilename), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .lengthFilter)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "ont-reads-subset",
                parentBundleRelativePath: "@/Imports/ont-reads.lungfishfastq",
                rootBundleRelativePath: "@/Imports/ont-reads.lungfishfastq",
                rootFASTQFilename: "reads.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: listed.count, baseCount: 0),
                pairingMode: .singleEnd
            ),
            in: bundle
        )
        return bundle.standardizedFileURL
    }

    /// An Illumina root of fragments f1 to f3, each R1 record followed by its
    /// R2 record with Casava comments, and a virtual length-filter subset
    /// whose list names f1 and f3, with the preview of f1 the subset writes.
    static func makeIlluminaSubset(in directory: URL, sequence: String = "ACGTACGT") throws -> IlluminaSubset {
        let fm = FileManager.default
        let project = directory.appendingPathComponent("Illumina Subset.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let rootBundle = imports.appendingPathComponent("pairs.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFile = rootBundle.appendingPathComponent("reads.fastq")
        let fragments = ["f1", "f2", "f3"]
        try fragments.flatMap { [record("\($0) 1:N:0:1", sequence), record("\($0) 2:N:0:1", sequence)] }.joined()
            .write(to: rootFile, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected),
                sequencingPlatform: .illumina
            ),
            for: rootFile
        )

        let bundle = imports.appendingPathComponent("pairs-subset.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "f1\nf3\n".write(to: bundle.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        let previewReads = ["f1 1:N:0:1", "f1 2:N:0:1"]
        try previewReads.map { record($0, sequence) }.joined()
            .write(to: bundle.appendingPathComponent(previewFilename), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .lengthFilter)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "pairs-subset",
                parentBundleRelativePath: "@/Imports/pairs.lungfishfastq",
                rootBundleRelativePath: "@/Imports/pairs.lungfishfastq",
                rootFASTQFilename: "reads.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 4, baseCount: Int64(4 * sequence.count)),
                pairingMode: .interleaved
            ),
            in: bundle
        )
        return IlluminaSubset(
            projectURL: project,
            rootBundle: rootBundle.standardizedFileURL,
            bundle: bundle.standardizedFileURL,
            previewReads: previewReads
        )
    }
}
