// FastqTranslateMateIdTests.swift - The two mates of a Casava pair reach `fastq translate` under two FASTA ids
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.27 (decision [9] part B, vote T2). `FASTQReader` cuts a read id at the first space, so the
// two mates of a Casava 1.8 pair, which differ only after that space (`1:N:0:...` and `2:N:0:...`), used to reach
// the FASTA header under one id. M1 showed that as a red test (`testInterleavedCasavaMatesGetDistinctIds` failed
// on the ids with the layout already `strictlyInterleaved`), and M2 turns it into a byte for byte check. Two
// adjacent records take the marks `.1` and `.2` between the read id and `_frame` when the layout is interleaved
// or mixed with pairs, their ids are byte-equal and the contract's pair rule reads them as mates.

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport

final class FastqTranslateMateIdTests: XCTestCase {
    private typealias Fixture = FastqTranslateInputFixture
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "fastq-translate-mate-ids")
        let captured = folder!
        addTeardownBlock { TestTempDirectory.cleanup(captured) }
    }

    // MARK: Helpers

    private static let read1 = "ATGGCTAGCAAAGGAGAA"
    private static let read2 = "ATGAAACCCGGGTTT"

    private static func casavaID(_ tile: Int) -> String { "A00123:8:H7KJ2DSXX:1:1101:\(tile):1000" }

    private static func fastq(_ records: [(header: String, sequence: String)]) -> String {
        records
            .flatMap { [$0.header, $0.sequence, "+", String(repeating: "I", count: $0.sequence.count)] }
            .joined(separator: "\n") + "\n"
    }

    private func writeFASTQ(_ text: String, named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func writeBundle(_ text: String, named name: String, metadata: PersistedFASTQMetadata) throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let file = bundle.appendingPathComponent("reads.fastq")
        try Data(text.utf8).write(to: file)
        FASTQMetadataStore.save(metadata, for: file)
        return bundle
    }

    private func translated(_ input: URL, frame: Int = 1, to name: String) async throws -> String {
        let written = try await runFastqTranslatePin(input, frame: frame, output: folder.appendingPathComponent(name))
        return String(decoding: written, as: UTF8.self)
    }

    private func headerIDs(of fasta: String) -> [String] {
        fasta.split(separator: "\n").filter { $0.hasPrefix(">") }.map { String($0.dropFirst().prefix { $0 != " " }) }
    }

    // MARK: Pairs that take the marks

    /// BIO's fixture as a loose interleaved file and as a bundle recorded `interleaved`, at frames 1 and 4.
    func testInterleavedCasavaMatesGetDistinctIds() async throws {
        let loose = try writeFASTQ(Fixture.casava, named: "interleaved.fastq")
        let bundle = try writeFASTQBundlePin(Fixture.casava, named: "paired", in: folder, pairingMode: .interleaved)
        let inputs = [
            (label: "a loose interleaved file", input: loose, name: "loose"),
            (label: "a bundle recorded interleaved", input: bundle, name: "bundle"),
        ]
        for (label, input, name) in inputs {
            // The layout comes first, so a difference below is about the ids.
            XCTAssertEqual(resolvedLayoutPin(input), .strictlyInterleaved, label)

            let frame1 = try await translated(input, frame: 1, to: "\(name)-1.fa")
            let frame4 = try await translated(input, frame: 4, to: "\(name)-4.fa")

            XCTAssertEqual(frame1, Fixture.casavaFrame1, label)
            XCTAssertEqual(frame4, Fixture.casavaFrame4, label)
            let ids = headerIDs(of: frame1)
            XCTAssertEqual(Set(ids).count, ids.count, "\(label): the four FASTA ids must be distinct")
        }
    }

    /// BIO's two lines after M2 for the first fragment (`SCR/votes/BIO.md` V1), each ending in one LF.
    func testTheFirstFragmentHeadersAreBIOsAfterLinesByteForByte() async throws {
        let input = try writeFASTQ(Fixture.casava, named: "interleaved.fastq")

        let frame1 = try await translated(input, frame: 1, to: "frame-1.fa")

        let lines = frame1.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(
            String(lines[0]) + "\n" + String(lines[2]) + "\n",
            ">A00123:8:H7KJ2DSXX:1:1101:10004:1000.1_frame+1 [Standard] [6 aa]\n"
                + ">A00123:8:H7KJ2DSXX:1:1101:10004:1000.2_frame+1 [Standard] [5 aa]\n"
        )
        // The added bytes are 0x2E 0x31 and 0x2E 0x32, right after the read id.
        let bytes = Array(frame1.utf8)
        let idLength = ">A00123:8:H7KJ2DSXX:1:1101:10004:1000".utf8.count
        XCTAssertEqual(Array(bytes[idLength..<(idLength + 2)]), [0x2E, 0x31])
    }

    /// The number comes from the input record, so the second mate is still 2 when the first has no protein.
    func testSecondMateKeepsItsNumberWhenTheFirstMateGivesNoProtein() async throws {
        let text = Self.fastq([
            ("@\(Self.casavaID(10004)) 1:N:0:ACGTACGT", "AC"),
            ("@\(Self.casavaID(10004)) 2:N:0:ACGTACGT", Self.read2),
            ("@\(Self.casavaID(10005)) 1:N:0:ACGTACGT", Self.read1),
            ("@\(Self.casavaID(10005)) 2:N:0:ACGTACGT", Self.read2),
        ])
        let input = try writeFASTQ(text, named: "short-mate.fastq")
        XCTAssertEqual(resolvedLayoutPin(input), .strictlyInterleaved)

        let frame1 = try await translated(input, to: "short-mate.fa")

        XCTAssertEqual(frame1, [
            ">\(Self.casavaID(10004)).2_frame+1 [Standard] [5 aa]", "MKPGF",
            ">\(Self.casavaID(10005)).1_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(Self.casavaID(10005)).2_frame+1 [Standard] [5 aa]", "MKPGF",
        ].joined(separator: "\n") + "\n")
    }

    /// A merged read between two pairs keeps its id, and the pairs take the marks.
    func testMixedStreamMatesGetDistinctIds() async throws {
        let text = Self.fastq([
            ("@\(Self.casavaID(10004)) 1:N:0:ACGTACGT", Self.read1),
            ("@\(Self.casavaID(10004)) 2:N:0:ACGTACGT", Self.read2),
            ("@\(Self.casavaID(10006))", Self.read1),
            ("@\(Self.casavaID(10005)) 1:N:0:ACGTACGT", Self.read1),
            ("@\(Self.casavaID(10005)) 2:N:0:ACGTACGT", Self.read2),
        ])
        let input = try writeFASTQ(text, named: "mixed.fastq")
        XCTAssertEqual(resolvedLayoutPin(input), .mixedMergedAndPairs)

        let frame1 = try await translated(input, to: "mixed.fa")

        XCTAssertEqual(frame1, [
            ">\(Self.casavaID(10004)).1_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(Self.casavaID(10004)).2_frame+1 [Standard] [5 aa]", "MKPGF",
            ">\(Self.casavaID(10006))_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(Self.casavaID(10005)).1_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(Self.casavaID(10005)).2_frame+1 [Standard] [5 aa]", "MKPGF",
        ].joined(separator: "\n") + "\n")
    }

    // MARK: Inputs that keep their bytes

    /// An Oxford Nanopore bundle is never paired, so repeated ids get no mate label.
    func testLongReadBundleWithRepeatedIdsKeepsItsBytes() async throws {
        let id = "8f2e0c7a-0001-4f7a-9d1a-0123456789ab"
        let text = Self.fastq([("@\(id) runid=abc", Self.read1), ("@\(id) runid=abc", Self.read2)])
        var metadata = PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore)
        metadata.ingestion = IngestionMetadata(pairingMode: .singleEnd, pairingSource: .detected)
        let bundle = try writeBundle(text, named: "ont", metadata: metadata)
        // The resolver reads the recorded platform, so the layout is single reads and translate's bytes stay the same.
        XCTAssertEqual(resolvedLayoutPin(bundle), .singleEnd)

        let frame1 = try await translated(bundle, to: "ont.fa")

        XCTAssertEqual(frame1, [
            ">\(id)_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(id)_frame+1 [Standard] [5 aa]", "MKPGF",
        ].joined(separator: "\n") + "\n")
    }

    /// A PacBio bundle is never paired either, so repeated ids get no mate label. The help names PacBio beside
    /// Oxford Nanopore, and this pins the second name (12.27 review fix 1).
    func testPacBioBundleWithRepeatedIdsKeepsItsBytes() async throws {
        let id = "8f2e0c7a-0001-4f7a-9d1a-0123456789ab"
        let text = Self.fastq([("@\(id) runid=abc", Self.read1), ("@\(id) runid=abc", Self.read2)])
        var metadata = PersistedFASTQMetadata(sequencingPlatform: .pacbio)
        metadata.ingestion = IngestionMetadata(pairingMode: .singleEnd, pairingSource: .detected)
        let bundle = try writeBundle(text, named: "pacbio", metadata: metadata)
        // The resolver reads the recorded platform, so the layout is single reads and translate's bytes stay the same.
        XCTAssertEqual(resolvedLayoutPin(bundle), .singleEnd)

        let frame1 = try await translated(bundle, to: "pacbio.fa")

        XCTAssertEqual(frame1, [
            ">\(id)_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(id)_frame+1 [Standard] [5 aa]", "MKPGF",
        ].joined(separator: "\n") + "\n")
    }

    /// A derived bundle whose own sidecar records no platform keeps its bytes when the bundle it derives from
    /// records Oxford Nanopore. This reaches the ancestor walk of `FASTQLongReadRule.recordedPlatform(of:)`, which
    /// the bundle test above does not (UX ruling 3, BIO answer 3).
    func testLongReadDerivativeWithRepeatedIdsKeepsItsBytes() async throws {
        let id = "8f2e0c7a-0001-4f7a-9d1a-0123456789ab"
        let text = Self.fastq([("@\(id) runid=abc", Self.read1), ("@\(id) runid=abc", Self.read2)])
        let imports = folder.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let parent = imports.appendingPathComponent("ont.lungfishfastq", isDirectory: true)
        let child = imports.appendingPathComponent("ont-subset.lungfishfastq", isDirectory: true)
        for bundle in [parent, child] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: bundle.appendingPathComponent("reads.fastq"))
        }
        // Only the parent's sidecar records the platform.
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore),
            for: parent.appendingPathComponent("reads.fastq")
        )
        let operation = FASTQDerivativeOperation(kind: .deduplicate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "ont-subset",
                parentBundleRelativePath: "@/Imports/ont.lungfishfastq",
                rootBundleRelativePath: "@/Imports/ont.lungfishfastq",
                rootFASTQFilename: "reads.fastq",
                payload: .full(fastqFilename: "reads.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 33),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: child
        )
        XCTAssertNil(FASTQMetadataStore.load(for: child.appendingPathComponent("reads.fastq")))
        // The resolver reads the parent's recorded platform, so the layout is single reads; translate's bytes stay the same.
        XCTAssertEqual(resolvedLayoutPin(child), .singleEnd)

        let frame1 = try await translated(child, to: "ont-derived.fa")

        XCTAssertEqual(frame1, [
            ">\(id)_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(id)_frame+1 [Standard] [5 aa]", "MKPGF",
        ].joined(separator: "\n") + "\n")
    }

    /// A mixed file recorded `single_end`, with counts that show its merged read, keeps its bytes.
    func testMixedFileRecordedSingleEndKeepsItsBytes() async throws {
        let text = Self.fastq([
            ("@\(Self.casavaID(10004)) 1:N:0:ACGTACGT", Self.read1),
            ("@\(Self.casavaID(10004)) 2:N:0:ACGTACGT", Self.read2),
            ("@\(Self.casavaID(10006))", Self.read1),
        ])
        let metadata = PersistedFASTQMetadata(
            ingestion: IngestionMetadata(pairingMode: .singleEnd, pairingSource: .detected),
            readClassification: ReadClassification(files: [
                .init(filename: "reads.fastq", role: .merged, readCount: 1),
                .init(filename: "reads.fastq", role: .pairedR1, readCount: 1),
                .init(filename: "reads.fastq", role: .pairedR2, readCount: 1),
            ])
        )
        let bundle = try writeBundle(text, named: "mixed-single-end", metadata: metadata)
        // The resolver alone numbers these pairs, so the recorded label is what keeps the bytes.
        XCTAssertEqual(resolvedLayoutPin(bundle), .mixedMergedAndPairs)

        let frame1 = try await translated(bundle, to: "mixed-single-end.fa")

        XCTAssertEqual(frame1, [
            ">\(Self.casavaID(10004))_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(Self.casavaID(10004))_frame+1 [Standard] [5 aa]", "MKPGF",
            ">\(Self.casavaID(10006))_frame+1 [Standard] [6 aa]", "MASKGE",
        ].joined(separator: "\n") + "\n")
    }

    /// The other side of the carve-out. The same mixed file recorded `interleaved`, as a legacy bundle is, follows
    /// the resolver, so its pairs take the marks and its merged read keeps its id (12.27 review fix 3).
    func testMixedBundleRecordedInterleavedNumbersItsPairs() async throws {
        let text = Self.fastq([
            ("@\(Self.casavaID(10004)) 1:N:0:ACGTACGT", Self.read1),
            ("@\(Self.casavaID(10004)) 2:N:0:ACGTACGT", Self.read2),
            ("@\(Self.casavaID(10006))", Self.read1),
        ])
        let metadata = PersistedFASTQMetadata(
            ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected),
            readClassification: ReadClassification(files: [
                .init(filename: "reads.fastq", role: .merged, readCount: 1),
                .init(filename: "reads.fastq", role: .pairedR1, readCount: 1),
                .init(filename: "reads.fastq", role: .pairedR2, readCount: 1),
            ])
        )
        let bundle = try writeBundle(text, named: "mixed-interleaved", metadata: metadata)
        XCTAssertEqual(resolvedLayoutPin(bundle), .mixedMergedAndPairs)

        let frame1 = try await translated(bundle, to: "mixed-interleaved.fa")

        XCTAssertEqual(frame1, [
            ">\(Self.casavaID(10004)).1_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(Self.casavaID(10004)).2_frame+1 [Standard] [5 aa]", "MKPGF",
            ">\(Self.casavaID(10006))_frame+1 [Standard] [6 aa]", "MASKGE",
        ].joined(separator: "\n") + "\n")
    }
}
