// FASTQInputLayoutLongReadTests.swift - The layout resolver reads a recorded long-read platform before the scan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.42 M2, BIO ruling tests T3 and T5 and the guards of section 3d. An Oxford Nanopore or PacBio
// bundle whose read ids repeat is read as single reads at both entries of `FASTQInputLayoutResolver`, while a
// stated layout, two bound files, a FASTA input and an Illumina bundle keep their answers.

import XCTest
@testable import LungfishIO
import LungfishTestSupport

final class FASTQInputLayoutLongReadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-layout-long-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Fixtures

    private var imports: URL { folder.appendingPathComponent("Project.lungfish/Imports", isDirectory: true) }

    private static let sequence = "ACGTACGTACGTACGTAC"

    /// Each id twice in a row, so the scan alone reads every two records as one mate pair.
    private static func repeatedIdFASTQ(_ headers: [String]) -> String {
        let quality = String(repeating: "I", count: sequence.count)
        return headers.flatMap { [$0, $0] }.map { "@\($0)\n\(sequence)\n+\n\(quality)\n" }.joined()
    }

    private static let ontText = repeatedIdFASTQ([
        "8f2e0c7a-0001-4f7a-9d1a-0123456789ab runid=abc",
        "8f2e0c7a-0002-4f7a-9d1a-0123456789ab runid=abc",
    ])

    private static let pacbioText = repeatedIdFASTQ(["m64011_190830_220126/101/ccs", "m64011_190830_220126/102/ccs"])

    private func makeRoot(_ name: String, _ text: String, platform: SequencingPlatform) throws -> URL {
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try Data(text.utf8).write(to: reads)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: platform), for: reads)
        return bundle
    }

    /// M1's ont-child, a deduplicate child of `parent` whose own sidecar records nothing.
    private func makeChild(of parent: URL) throws -> URL {
        let child = imports.appendingPathComponent("ont-subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(Self.ontText.utf8).write(to: child.appendingPathComponent("reads.fastq"))
        let operation = FASTQDerivativeOperation(kind: .deduplicate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "ont-subset",
                parentBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootFASTQFilename: "reads.fastq",
                payload: .full(fastqFilename: "reads.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: 4, baseCount: 72),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: child
        )
        return child
    }

    /// A copy of `reads` away from every bundle, with no sidecar, as a materialization is.
    private func scratchCopy(of reads: URL, named name: String) throws -> URL {
        let scratch = folder.appendingPathComponent("scratch-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent("reads.fastq")
        try FileManager.default.copyItem(at: reads, to: copy)
        return copy
    }

    /// A multi-file root as the ONT importer writes it. Its reads sit in `chunks/reads.fastq`, which `source-files.json`
    /// lists, and the platform sits on the bundle's sidecar and on no chunk, so only the bundle can say it.
    private func makeChunkedRoot(_ name: String, _ text: String, platform: SequencingPlatform) throws -> (bundle: URL, nested: URL) {
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let nested = chunks.appendingPathComponent("reads.fastq")
        try Data(text.utf8).write(to: nested)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/reads.fastq", originalPath: "/orig/reads.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: platform), for: bundle)
        return (bundle, nested)
    }

    // MARK: - T3 and T5

    func testLongReadRootsAreSingleReadsAtEveryEntry() throws {
        let roots: [(name: String, text: String, platform: SequencingPlatform)] = [
            ("ont", Self.ontText, .oxfordNanopore),
            ("pacbio", Self.pacbioText, .pacbio),
        ]
        for root in roots {
            let bundle = try makeRoot(root.name, root.text, platform: root.platform)
            let reads = bundle.appendingPathComponent("reads.fastq")
            let copy = try scratchCopy(of: reads, named: root.name)
            // The scan alone reads the copy as pairs, so only the platform makes these single reads.
            XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [copy]).layout, .strictlyInterleaved)
            let resolutions: [(label: String, resolution: FASTQInputLayoutResolution)] = [
                ("the bundle", FASTQInputLayoutResolver.resolve(inputURLs: [bundle])),
                ("its reads.fastq", FASTQInputLayoutResolver.resolve(inputURLs: [reads])),
                ("a copy hinted by the bundle", FASTQInputLayoutResolver.resolve(fastqURL: copy, metadataFrom: bundle)),
                ("a copy hinted by reads.fastq", FASTQInputLayoutResolver.resolve(fastqURL: copy, metadataFrom: reads)),
            ]
            for (label, resolution) in resolutions {
                XCTAssertEqual(resolution.layout, .singleEnd, "\(root.name), \(label)")
                XCTAssertEqual(resolution.source, .bundleMetadata, "\(root.name), \(label)")
                XCTAssertEqual(
                    resolution.reason,
                    "The bundle records \(root.platform.displayName) reads, which are never paired.",
                    "\(root.name), \(label)"
                )
            }
        }
    }

    func testChildHintedByItsOwnReadsFindsItsParentsPlatform() throws {
        let root = try makeRoot("ont", Self.ontText, platform: .oxfordNanopore)
        let child = try makeChild(of: root)
        let childReads = child.appendingPathComponent("reads.fastq")
        XCTAssertNil(FASTQMetadataStore.load(for: childReads))
        let copy = try scratchCopy(of: childReads, named: "ont-child")

        let resolution = FASTQInputLayoutResolver.resolve(fastqURL: copy, metadataFrom: childReads)

        XCTAssertEqual(resolution.layout, .singleEnd)
        XCTAssertEqual(resolution.source, .bundleMetadata)
        XCTAssertEqual(resolution.reason, "The bundle records Oxford Nanopore reads, which are never paired.")
    }

    /// A file two levels inside a bundle, a member of a multi-file root, has no sidecar of its own and no bundle one
    /// level above it. The base asked the enclosing bundle at any depth, so the rule does too (13.42 BIO review fix 1).
    func testFileTwoLevelsInsideLongReadBundleReadsTheBundlePlatform() throws {
        let nested = try makeChunkedRoot("ont", Self.ontText, platform: .oxfordNanopore).nested
        XCTAssertNil(FASTQMetadataStore.load(for: nested))
        // The scan alone reads the same bytes outside every bundle as pairs, so only the bundle makes these single reads.
        let copy = try scratchCopy(of: nested, named: "ont-nested")
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [copy]).layout, .strictlyInterleaved)

        let resolutions: [(label: String, resolution: FASTQInputLayoutResolution)] = [
            ("hinted by itself", FASTQInputLayoutResolver.resolve(fastqURL: nested, metadataFrom: nested)),
            ("named alone", FASTQInputLayoutResolver.resolve(inputURLs: [nested])),
        ]
        for (label, resolution) in resolutions {
            XCTAssertEqual(resolution.layout, .singleEnd, label)
            XCTAssertEqual(resolution.source, .bundleMetadata, label)
            XCTAssertEqual(resolution.reason, "The bundle records Oxford Nanopore reads, which are never paired.", label)
        }
    }

    // MARK: - Guards, the same answer at the base and after

    func testStatedLayoutStaysFinalOnAnOxfordNanoporeRoot() throws {
        let bundle = try makeRoot("ont", Self.ontText, platform: .oxfordNanopore)

        let resolution = FASTQInputLayoutResolver.resolve(
            inputURLs: [bundle.appendingPathComponent("reads.fastq")],
            explicit: .strictlyInterleaved
        )

        XCTAssertEqual(resolution.layout, .strictlyInterleaved)
        XCTAssertEqual(resolution.source, .explicit)
    }

    func testTwoBoundFilesStayPairedFilesInALongReadBundle() throws {
        let bundle = try makeRoot("ont", Self.ontText, platform: .oxfordNanopore)
        let second = bundle.appendingPathComponent("more.fastq")
        try Data(Self.ontText.utf8).write(to: second)

        let resolution = FASTQInputLayoutResolver.resolve(
            inputURLs: [bundle.appendingPathComponent("reads.fastq"), second],
            pairedFiles: true
        )

        XCTAssertEqual(resolution.layout, .pairedFiles)
        XCTAssertEqual(resolution.source, .pairedFiles)
    }

    func testIlluminaRootWithTheSameRepeatedIdsStaysInterleaved() throws {
        let bundle = try makeRoot("illumina", Self.ontText, platform: .illumina)

        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [bundle]).layout, .strictlyInterleaved)
        XCTAssertEqual(
            FASTQInputLayoutResolver.resolve(fastqURL: bundle.appendingPathComponent("reads.fastq"), metadataFrom: bundle)
                .layout,
            .strictlyInterleaved
        )
    }

    /// A derivative of an Oxford Nanopore root whose manifest records FASTA, so the bundle is a long-read bundle and
    /// its file is not FASTQ. The non-FASTQ step comes before the long-read step.
    func testFASTAInALongReadBundleKeepsItsNotFASTQSource() throws {
        let parent = try makeRoot("ont", Self.ontText, platform: .oxfordNanopore)
        let child = imports.appendingPathComponent("ont-contigs.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let fasta = child.appendingPathComponent("contigs.fasta")
        try Data(">contig1\nACGTACGT\n".utf8).write(to: fasta)
        let operation = FASTQDerivativeOperation(kind: .deduplicate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "ont-contigs",
                parentBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootBundleRelativePath: "@/Imports/\(parent.lastPathComponent)",
                rootFASTQFilename: "reads.fastq",
                payload: .full(fastqFilename: "contigs.fasta"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: 1, baseCount: 8),
                pairingMode: .singleEnd,
                sequenceFormat: .fasta
            ),
            in: child
        )
        XCTAssertEqual(FASTQLongReadRule.recordedPlatform(of: child), .oxfordNanopore)

        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [fasta]).source, .notFASTQ)
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(fastqURL: fasta, metadataFrom: child).source, .notFASTQ)
    }
}
