// MSAInputSequenceCounterTests.swift - MAFFT "All sequences (N)" count resolution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

final class MSAInputSequenceCounterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msa_input_count_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func writeFASTA(named name: String, records: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let text = records.map { ">\($0)\nACGTACGT\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A minimal `.lungfishref` whose manifest lists `names` as chromosomes.
    /// `listChromosomesInManifest: false` leaves the manifest list empty so the
    /// counter has to fall back to the `.fai` index.
    private func makeReferenceBundle(
        named bundleName: String,
        chromosomes names: [String],
        listChromosomesInManifest: Bool = true
    ) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let sequence = "ACGTACGTAC"
        var fasta = ""
        var fai = ""
        var infos: [ChromosomeInfo] = []
        var offset = 0
        for name in names {
            let header = ">\(name)\n"
            fasta += header + sequence + "\n"
            offset += header.utf8.count
            fai += "\(name)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
            infos.append(ChromosomeInfo(
                name: name, length: Int64(sequence.count), offset: Int64(offset),
                lineBases: sequence.count, lineWidth: sequence.count + 1
            ))
            offset += sequence.count + 1
        }
        try fasta.write(to: genomeDir.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try fai.write(to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: bundleName,
            identifier: "org.lungfish.tests.msa-count.\(bundleName)",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count * names.count),
                chromosomes: listChromosomesInManifest ? infos : []
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    // MARK: - Tests

    /// The reported case: a five-record reference bundle opened from Tools >
    /// Multiple Sequence Alignment > MAFFT showed "Aligning all 0 sequences."
    func testReferenceBundleCountComesFromManifestChromosomes() async throws {
        let bundle = try makeReferenceBundle(
            named: "primate-mito",
            chromosomes: ["human", "chimp", "gorilla", "orangutan", "macaque"]
        )

        let count = await MSAInputSequenceCounter.sequenceCount(for: bundle)
        XCTAssertEqual(count, 5)
        let total = await MSAInputSequenceCounter.sequenceCount(for: [bundle])
        XCTAssertEqual(total, 5)
    }

    func testReferenceBundleWithEmptyManifestListFallsBackToIndex() async throws {
        let bundle = try makeReferenceBundle(
            named: "unlisted",
            chromosomes: ["a", "b", "c"],
            listChromosomesInManifest: false
        )

        let count = await MSAInputSequenceCounter.sequenceCount(for: bundle)
        XCTAssertEqual(count, 3)
    }

    func testFileInsideReferenceBundleResolvesToTheBundle() async throws {
        let bundle = try makeReferenceBundle(named: "nested", chromosomes: ["x", "y"])
        let inner = bundle.appendingPathComponent("genome/sequence.fa")

        let count = await MSAInputSequenceCounter.sequenceCount(for: inner)
        XCTAssertEqual(count, 2)
    }

    func testLooseFASTAAndFASTQFilesAreCounted() async throws {
        let fasta = try writeFASTA(named: "three.fasta", records: ["r1", "r2", "r3"])
        let fastq = tempDir.appendingPathComponent("two.fastq")
        try "@q1\nACGT\n+\nIIII\n@q2\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)

        let fastaCount = await MSAInputSequenceCounter.sequenceCount(for: fasta)
        XCTAssertEqual(fastaCount, 3)
        let fastqCount = await MSAInputSequenceCounter.sequenceCount(for: fastq)
        XCTAssertEqual(fastqCount, 2)
        let total = await MSAInputSequenceCounter.sequenceCount(for: [fasta, fastq])
        XCTAssertEqual(total, 5)
    }

    func testUnreadableInputsContributeZeroWithoutFailing() async throws {
        let fasta = try writeFASTA(named: "one.fa", records: ["only"])
        let missing = tempDir.appendingPathComponent("missing.fa")
        let notSequence = tempDir.appendingPathComponent("notes.txt")
        try "hello".write(to: notSequence, atomically: true, encoding: .utf8)

        let missingCount = await MSAInputSequenceCounter.sequenceCount(for: missing)
        XCTAssertNil(missingCount)
        let textCount = await MSAInputSequenceCounter.sequenceCount(for: notSequence)
        XCTAssertNil(textCount)
        let total = await MSAInputSequenceCounter.sequenceCount(for: [fasta, missing, notSequence])
        XCTAssertEqual(total, 1)
    }

    @MainActor
    func testToolsRouteOnlyComputesCountForTheAlignmentPane() {
        XCTAssertTrue(AppDelegate.dialogShowsMAFFTSequenceScope(initialCategory: .alignment, initialToolID: nil))
        XCTAssertTrue(AppDelegate.dialogShowsMAFFTSequenceScope(initialCategory: .alignment, initialToolID: .mafft))
        XCTAssertTrue(AppDelegate.dialogShowsMAFFTSequenceScope(initialCategory: .mapping, initialToolID: .mafft))
        XCTAssertFalse(AppDelegate.dialogShowsMAFFTSequenceScope(initialCategory: .mapping, initialToolID: nil))
        XCTAssertFalse(AppDelegate.dialogShowsMAFFTSequenceScope(initialCategory: .assembly, initialToolID: .spades))
    }
}
