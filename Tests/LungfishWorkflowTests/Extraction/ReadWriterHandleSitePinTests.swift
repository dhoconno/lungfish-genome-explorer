// ReadWriterHandleSitePinTests.swift - Output bytes of the writers whose sink the interleaver and the extractor fill
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, the follow-up grant. The bytes of the three writers
/// whose output is filled by `FASTQPairInterleaver` or by
/// `TaxonomyExtractionPipeline.writeExtractedReads`, pinned before they move
/// onto `DurableReplace`. The mate interleaving of the materializer is pinned
/// in `ReadWriterBytePinTests`. These pass at the base and pass again after
/// the move.
final class ReadWriterHandleSitePinTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "handle-site-pins")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func record(_ name: String, _ base: Character) -> String {
        "@\(name)\n\(base)\(base)\(base)\(base)\n+\nIIII\n"
    }

    // MARK: - The importer's pairs, then the reads without a mate

    private func join(
        pairs: [String],
        singles: [String],
        gzipped: Bool = false,
        finalLineBreak: Bool = true
    ) async throws -> (name: String, text: String, counts: RecipeMixedLayoutCounts) {
        let folder = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let workspace = folder.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suffix = gzipped ? ".fastq.gz" : ".fastq"
        func input(_ data: Data, _ name: String) throws -> URL {
            try Fixtures.write(gzipped ? try Fixtures.gzip(data) : data, named: name + suffix, in: folder)
        }
        let r1 = try input(Fixtures.mates(pairs.map { "\($0)/1" }, base: "A", finalLineBreak: finalLineBreak), "S_R1")
        let r2 = try input(Fixtures.mates(pairs.map { "\($0)/2" }, base: "C", finalLineBreak: finalLineBreak), "S_R2")
        let unpaired = try input(Fixtures.mates(singles, base: "G", finalLineBreak: finalLineBreak), "S")
        let sample = SamplePair(sampleName: "S", r1: r1, r2: r2, unpaired: unpaired)

        let written = try await FASTQBatchImporter.writePairsThenUnpairedReads(of: sample, in: workspace, log: nil)
        let layout = try XCTUnwrap(written)

        return (
            layout.file.lastPathComponent,
            String(decoding: try Data(contentsOf: layout.file), as: UTF8.self),
            layout.counts
        )
    }

    private func expectedJoin(pairs: [String], singles: [String]) -> String {
        pairs.map { record("\($0)/1", "A") + record("\($0)/2", "C") }.joined()
            + singles.map { record($0, "G") }.joined()
    }

    func testTwoPairsAndThreeReadsWithoutAMateJoinAsPairsThenTheReads() async throws {
        let joined = try await join(pairs: ["p1", "p2"], singles: ["u1", "u2", "u3"])

        XCTAssertEqual(joined.name, "S_pairs_then_unpaired.fastq")
        XCTAssertEqual(joined.text, expectedJoin(pairs: ["p1", "p2"], singles: ["u1", "u2", "u3"]))
        XCTAssertEqual(joined.counts.pairs, 2)
        XCTAssertEqual(joined.counts.unpairedReads, 3)
        XCTAssertEqual(joined.counts.mergedReads, 0)
    }

    func testThreePairsAndOneReadWithoutAMateJoinAsPairsThenTheRead() async throws {
        let joined = try await join(pairs: ["p1", "p2", "p3"], singles: ["u1"])

        XCTAssertEqual(joined.text, expectedJoin(pairs: ["p1", "p2", "p3"], singles: ["u1"]))
        XCTAssertEqual(joined.counts.pairs, 3)
        XCTAssertEqual(joined.counts.unpairedReads, 1)
    }

    func testGzipInputsJoinAsPlainFASTQ() async throws {
        let joined = try await join(pairs: ["p1", "p2"], singles: ["u1", "u2"], gzipped: true)

        XCTAssertEqual(joined.text, expectedJoin(pairs: ["p1", "p2"], singles: ["u1", "u2"]))
        XCTAssertEqual(joined.counts.pairs, 2)
        XCTAssertEqual(joined.counts.unpairedReads, 2)
    }

    func testInputsWithoutAFinalLineBreakJoinToAFileThatEndsWithOne() async throws {
        let plain = try await join(pairs: ["p1", "p2"], singles: ["u1", "u2"], finalLineBreak: false)
        let gzipped = try await join(pairs: ["p1"], singles: ["u1"], gzipped: true, finalLineBreak: false)

        XCTAssertEqual(plain.text, expectedJoin(pairs: ["p1", "p2"], singles: ["u1", "u2"]))
        XCTAssertEqual(gzipped.text, expectedJoin(pairs: ["p1"], singles: ["u1"]))
    }

    // MARK: - Kraken2 extraction, pairs first

    private struct Extracted {
        let files: [KrakenResultReadSources.File]
        let outputs: [URL?]
        let pairs: Data
        let reads: Data
    }

    /// One sample's extraction: an interleaved output for the R1 and R2 files,
    /// then a reads file and a file of adjacent mates.
    private func extraction(_ label: String, folder: URL) throws -> Extracted {
        let pairs = Fixtures.mates(["\(label)p1/1", "\(label)p1/2", "\(label)p2/1", "\(label)p2/2"], base: "A")
        let reads = Fixtures.mates(["\(label)u1", "\(label)u2"], base: "G")
        let adjacent = Fixtures.mates(["\(label)m1/1", "\(label)m1/2"], base: "T")
        let outputs: [URL?] = [
            try Fixtures.write(pairs, named: "\(label)-pairs.fastq", in: folder),
            nil,
            try Fixtures.write(reads, named: "\(label)-reads.fastq", in: folder),
            try Fixtures.write(adjacent, named: "\(label)-adjacent.fastq", in: folder),
        ]
        let sources = folder.appendingPathComponent("sources")
        let files = [
            KrakenResultReadSources.File(url: sources.appendingPathComponent("\(label)_R1.fastq"), role: .r1),
            KrakenResultReadSources.File(url: sources.appendingPathComponent("\(label)_R2.fastq"), role: .r2),
            KrakenResultReadSources.File(url: sources.appendingPathComponent("\(label)_reads.fastq"), role: .reads),
            KrakenResultReadSources.File(url: sources.appendingPathComponent("\(label)_mates.fastq"), role: .adjacentMates),
        ]
        return Extracted(files: files, outputs: outputs, pairs: pairs, reads: reads + adjacent)
    }

    private func sink(_ name: String, in folder: URL) throws -> (url: URL, handle: FileHandle) {
        let url = folder.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        return (url, try FileHandle(forWritingTo: url))
    }

    func testExtractedReadsOfTwoSamplesPutAllPairsInOneFileAndAllOtherReadsInTheOtherInOrder() throws {
        let folder = root.appendingPathComponent("kraken", isDirectory: true)
        let first = try extraction("a", folder: folder)
        let second = try extraction("b", folder: folder)
        let pairsSink = try sink("pairs.fastq", in: folder)
        let readsSink = try sink("reads.fastq", in: folder)

        let firstPairs = try TaxonomyExtractionPipeline.writeExtractedReads(
            first.outputs, of: first.files, pairs: pairsSink.handle, reads: readsSink.handle
        )
        let secondPairs = try TaxonomyExtractionPipeline.writeExtractedReads(
            second.outputs, of: second.files, pairs: pairsSink.handle, reads: readsSink.handle
        )
        try pairsSink.handle.close()
        try readsSink.handle.close()

        XCTAssertEqual(firstPairs, 2)
        XCTAssertEqual(secondPairs, 2)
        XCTAssertEqual(try Data(contentsOf: pairsSink.url), first.pairs + second.pairs)
        XCTAssertEqual(try Data(contentsOf: readsSink.url), first.reads + second.reads)
    }

    func testExtractedReadsToOneHandleGetThePairsBeforeTheOtherReads() throws {
        let folder = root.appendingPathComponent("kraken-one", isDirectory: true)
        let extracted = try extraction("a", folder: folder)
        let both = try sink("both.fastq", in: folder)

        _ = try TaxonomyExtractionPipeline.writeExtractedReads(
            extracted.outputs, of: extracted.files, pairs: both.handle, reads: both.handle
        )
        try both.handle.close()

        XCTAssertEqual(try Data(contentsOf: both.url), extracted.pairs + extracted.reads)
    }

    func testAKraken2ExtractionOfTheFixtureWritesItsTwoPairsByteForByte() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Extraction
            .deletingLastPathComponent() // LungfishWorkflowTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/kraken2-bracken-reopen")
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".lungfish"),
            withIntermediateDirectories: true
        )
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let resultDir = analyses.appendingPathComponent("kraken2-2026-09-24T23-36-28")
        try FileManager.default.copyItem(at: fixture, to: resultDir)

        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2,
            resultPath: resultDir,
            selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [3050292])],
            options: ExtractionOptions(),
            destination: .bundle(
                projectRoot: project,
                displayName: "kraken2_Simplexvirus_pin",
                metadata: ExtractionMetadata(
                    sourceDescription: "kraken2_Simplexvirus_pin",
                    toolName: "Kraken2",
                    parameters: ["taxIds": "3050292"]
                )
            )
        )

        guard case .bundle(let bundleURL, let readCount) = outcome else {
            return XCTFail("expected a bundle outcome, got \(outcome)")
        }
        XCTAssertEqual(readCount, 4)
        let payload = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "fastq" }
        )
        let source = try String(contentsOf: fixture.appendingPathComponent("source.fastq"), encoding: .utf8)
        let firstTwoPairs = source.split(separator: "\n", omittingEmptySubsequences: false).prefix(16)
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: payload), as: UTF8.self),
            firstTwoPairs.joined(separator: "\n") + "\n"
        )
    }
}
