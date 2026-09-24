// FASTQMixedLayoutConsumerTests.swift - Mixed (merged reads plus pairs) input never pairs by position
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner contract (FASTQInputLayout.swift): every FASTQ consumer accommodates
// a file that mixes merged single reads with unmerged pairs, and treats it
// as single reads when it cannot pair it gracefully. These tests cover the
// in-process pieces the consumers share: the by-name partition, the Kraken2
// re-check of a forced interleaved request, and the Illumina MHC merge that
// merges only the strict pairs of a mixed file.

import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class FASTQMixedLayoutConsumerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-layout-consumers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openForWriting(_ url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try XCTUnwrap(FileHandle(forWritingAtPath: url.path))
    }

    // MARK: - FASTQPairInterleaver.partitionMixed

    func testPartitionMixedSplitsPairsByNameAndPassesMergedReadsThrough() async throws {
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let mixed = root.appendingPathComponent("mixed-\(naming.rawValue).fastq")
            try InterleavedFASTQFixture.writeMixed(pairCount: 9, mergedCount: 4, naming: naming, to: mixed)
            let r1 = root.appendingPathComponent("\(naming.rawValue)-R1.fastq")
            let r2 = root.appendingPathComponent("\(naming.rawValue)-R2.fastq")
            let unpaired = root.appendingPathComponent("\(naming.rawValue)-unpaired.fastq")
            let handles = try [r1, r2, unpaired].map(openForWriting)
            let counts = try FASTQPairInterleaver.partitionMixed(
                interleaved: mixed, r1: handles[0], r2: handles[1], unpaired: handles[2]
            )
            for handle in handles { try handle.close() }

            XCTAssertEqual(counts, FASTQPairInterleaver.MixedCounts(pairs: 9, unpaired: 4), "\(naming)")
            let mates1 = try await InterleavedFASTQFixture.readRecords(at: r1)
            let mates2 = try await InterleavedFASTQFixture.readRecords(at: r2)
            let singles = try await InterleavedFASTQFixture.readRecords(at: unpaired)
            XCTAssertEqual(mates1.map(InterleavedFASTQFixture.fragmentKey), (0..<9).map(InterleavedFASTQFixture.fragmentName), "\(naming)")
            XCTAssertEqual(mates2.map(InterleavedFASTQFixture.fragmentKey), (0..<9).map(InterleavedFASTQFixture.fragmentName), "\(naming)")
            XCTAssertEqual(mates1.map(\.sequence), (0..<9).map { InterleavedFASTQFixture.defaultSequences($0).mate1 }, "\(naming)")
            XCTAssertEqual(mates2.map(\.sequence), (0..<9).map { InterleavedFASTQFixture.defaultSequences($0).mate2 }, "\(naming)")
            XCTAssertEqual(singles.map(\.identifier), (0..<4).map(InterleavedFASTQFixture.mergedName), "\(naming)")
        }
    }

    func testPartitionMixedIntoPairsFileKeepsMatesAdjacentAndStrict() async throws {
        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 6, mergedCount: 6, naming: .identical, to: mixed)
        let pairs = root.appendingPathComponent("pairs.fastq")
        let unpaired = root.appendingPathComponent("unpaired.fastq")
        let pairsHandle = try openForWriting(pairs)
        let unpairedHandle = try openForWriting(unpaired)
        let counts = try FASTQPairInterleaver.partitionMixed(interleaved: mixed, pairs: pairsHandle, unpaired: unpairedHandle)
        try pairsHandle.close()
        try unpairedHandle.close()

        XCTAssertEqual(counts, FASTQPairInterleaver.MixedCounts(pairs: 6, unpaired: 6))
        let pairRecords = try await InterleavedFASTQFixture.readRecords(at: pairs)
        InterleavedFASTQFixture.assertWholePairs(pairRecords)
        XCTAssertEqual(pairRecords.count, 12)
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [pairs]).layout, .strictlyInterleaved)
        let singles = try await InterleavedFASTQFixture.readRecords(at: unpaired)
        XCTAssertEqual(singles.count, 6)
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [unpaired]).layout, .singleEnd)
    }

    func testPartitionOfAStrictFileLeavesTheUnpairedStreamEmpty() async throws {
        let strict = root.appendingPathComponent("strict.fastq")
        try InterleavedFASTQFixture.write(pairCount: 5, naming: .casava, to: strict)
        let r1 = root.appendingPathComponent("R1.fastq")
        let r2 = root.appendingPathComponent("R2.fastq")
        let unpaired = root.appendingPathComponent("unpaired.fastq")
        let handles = try [r1, r2, unpaired].map(openForWriting)
        let counts = try FASTQPairInterleaver.partitionMixed(interleaved: strict, r1: handles[0], r2: handles[1], unpaired: handles[2])
        for handle in handles { try handle.close() }
        XCTAssertEqual(counts, FASTQPairInterleaver.MixedCounts(pairs: 5, unpaired: 0))
        XCTAssertEqual(try Data(contentsOf: unpaired).count, 0)
    }

    // MARK: - Kraken2 forced interleaved request

    private func classificationConfig(inputFile: URL, interleavedInput: Bool) -> ClassificationConfig {
        ClassificationConfig(
            inputFiles: [inputFile],
            isPairedEnd: false,
            interleavedInput: interleavedInput,
            databaseName: "Viral",
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
            outputDirectory: root.appendingPathComponent("out", isDirectory: true)
        )
    }

    func testKraken2KeepsAForcedInterleavedRequestForStrictPairs() throws {
        let strict = root.appendingPathComponent("strict.fastq")
        try InterleavedFASTQFixture.write(pairCount: 10, naming: .identical, to: strict)
        let reconciled = ClassificationPipeline.reconcileInterleavedRequest(
            classificationConfig(inputFile: strict, interleavedInput: true)
        )
        XCTAssertTrue(reconciled.config.interleavedInput)
        XCTAssertEqual(reconciled.config.readFormat, .interleaved)
        XCTAssertEqual(reconciled.resolution?.layout, .strictlyInterleaved)
        XCTAssertNil(reconciled.warning)
    }

    func testKraken2FallsBackToUnpairedWithAWarningForAMixedFile() throws {
        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 10, mergedCount: 3, naming: .identical, to: mixed)
        let reconciled = ClassificationPipeline.reconcileInterleavedRequest(
            classificationConfig(inputFile: mixed, interleavedInput: true)
        )
        XCTAssertFalse(reconciled.config.interleavedInput, "A mixed file must not be split by position")
        XCTAssertFalse(reconciled.config.isPairedEnd)
        XCTAssertEqual(reconciled.config.readFormat, .unpaired)
        XCTAssertEqual(reconciled.config.inputLayout?.layout, .mixedInterleaved)
        XCTAssertEqual(reconciled.resolution?.layout, .mixedMergedAndPairs)
        let warning = try XCTUnwrap(reconciled.warning)
        XCTAssertTrue(warning.contains("single-end"), warning)
    }

    func testKraken2LeavesAnUnpairedRequestAlone() throws {
        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 4, mergedCount: 2, naming: .identical, to: mixed)
        let config = classificationConfig(inputFile: mixed, interleavedInput: false)
        let reconciled = ClassificationPipeline.reconcileInterleavedRequest(config)
        XCTAssertEqual(reconciled.config, config)
        XCTAssertNil(reconciled.resolution)
        XCTAssertNil(reconciled.warning)
    }

    // MARK: - Illumina MHC pair merge

    func testMergerPartitionsAMixedInputIntoStrictPairsAndUnpairedReads() async throws {
        let mixed = root.appendingPathComponent("sample.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 7, mergedCount: 3, naming: .casava, to: mixed)
        let partition = try IlluminaAmpliconPairMerger.partitionMixedInput(
            fastqURL: mixed, workingDirectory: root, stem: "sample"
        )
        XCTAssertEqual(partition.counts, FASTQPairInterleaver.MixedCounts(pairs: 7, unpaired: 3))
        let pairRecords = try await InterleavedFASTQFixture.readRecords(at: partition.pairsURL)
        InterleavedFASTQFixture.assertWholePairs(pairRecords)
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [partition.pairsURL]).layout, .strictlyInterleaved)
        let singles = try await InterleavedFASTQFixture.readRecords(at: partition.unpairedURL)
        XCTAssertEqual(singles.map(\.identifier), (0..<3).map(InterleavedFASTQFixture.mergedName))
    }

    func testMergerPassesASingleEndOrMergedFileThroughUntouched() async throws {
        let merged = root.appendingPathComponent("premerged.fastq")
        let text = (0..<6).map { "@\(InterleavedFASTQFixture.mergedName($0))\n\(InterleavedFASTQFixture.defaultMergedSequence($0))\n+\n\(String(repeating: "I", count: 100))" }
            .joined(separator: "\n") + "\n"
        try text.write(to: merged, atomically: true, encoding: .utf8)
        let outcome = try await IlluminaAmpliconPairMerger.prepareForMapping(
            fastqURL: merged,
            bbmergeURL: URL(fileURLWithPath: "/nonexistent/bbmerge.sh"),
            workingDirectory: root.appendingPathComponent("merge", isDirectory: true),
            stem: "premerged",
            threads: 1
        )
        XCTAssertEqual(outcome.disposition, .alreadyMerged)
        XCTAssertEqual(outcome.mappingFASTQURL, merged)
        XCTAssertEqual(outcome.mappingReadCount, 6)
    }

    func testMergerMergesOnlyTheStrictPairsOfAMixedFileAndKeepsMergedReads() async throws {
        let bbmergeURL = try await ToolAvailability.require("bbmerge.sh", environment: "bbtools")
        // Overlapping mates: mate 2 is the reverse complement of the tail of
        // mate 1 plus fresh sequence, so bbmerge joins every pair.
        let fragment = InterleavedFASTQFixture.deterministicSequence(seed: 77, length: 150)
        let overlapping: InterleavedFASTQFixture.PairSequences = { index in
            let insert = String(fragment.dropFirst(index % 5))
            let mate1 = String(insert.prefix(100))
            let mate2Forward = String(insert.suffix(100))
            let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A"]
            let mate2 = String(mate2Forward.reversed().map { complement[$0] ?? "N" })
            return (mate1, mate2)
        }
        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(
            pairCount: 8, mergedCount: 5, naming: .casava, sequences: overlapping, to: mixed
        )
        let outcome = try await IlluminaAmpliconPairMerger.prepareForMapping(
            fastqURL: mixed,
            bbmergeURL: bbmergeURL,
            workingDirectory: root.appendingPathComponent("merge", isDirectory: true),
            stem: "mixed",
            threads: 2
        )
        XCTAssertEqual(outcome.disposition, .merged)
        XCTAssertEqual(outcome.pairCount, 8, "only the 8 strict pairs reach bbmerge")
        XCTAssertEqual(outcome.unpairedPassthroughCount, 5)
        XCTAssertEqual(outcome.mergedCount + outcome.unmergedReadCount / 2, 8)
        let mapping = try await InterleavedFASTQFixture.readRecords(at: outcome.mappingFASTQURL)
        XCTAssertEqual(mapping.count, outcome.mappingReadCount)
        XCTAssertEqual(mapping.count, outcome.mergedCount + outcome.unmergedReadCount + 5)
        let passthrough = mapping.filter { $0.identifier.hasPrefix("merged") }
        XCTAssertEqual(passthrough.map(\.identifier), (0..<5).map(InterleavedFASTQFixture.mergedName), "merged reads pass through in order")
        XCTAssertEqual(passthrough.map(\.sequence), (0..<5).map(InterleavedFASTQFixture.defaultMergedSequence), "merged reads are untouched")
    }
}
