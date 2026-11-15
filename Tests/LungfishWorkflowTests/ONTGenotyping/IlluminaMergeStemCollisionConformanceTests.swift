// IlluminaMergeStemCollisionConformanceTests.swift - The real bbmerge keeps two samples' merged reads apart
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Runs the managed bbmerge on small synthetic overlapping pairs for the sample IDs `S-1` and `S--1`,
// which fold to one file stem. The stem each sample gives the merger must keep its merged reads in a
// file of its own. The test skips when bbtools is not installed and fails when LUNGFISH_REQUIRE_TOOLS=1
// is set. The unit cases in IlluminaMergeStemCollisionTests run no tool.

import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class IlluminaMergeStemCollisionConformanceTests: XCTestCase {
    private typealias Pipeline = ONTBarcodeDemuxGenotypingPipeline
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("illumina-merge-stem-conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A"]
        return String(sequence.reversed().map { complement[$0] ?? "N" })
    }

    /// Pairs cut from `fragment`. Mate 1 is the first 100 bases of the insert and mate 2 is the reverse
    /// complement of its last 100, so the mates overlap by about 50 bases and bbmerge can join each pair.
    private static func overlappingPairs(of fragment: String) -> InterleavedFASTQFixture.PairSequences {
        return { index in
            let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A"]
            let insert = String(fragment.dropFirst(index % 5))
            let mate1 = String(insert.prefix(100))
            let mate2 = String(insert.suffix(100).reversed().map { complement[$0] ?? "N" })
            return (mate1, mate2)
        }
    }

    // MARK: - Case

    /// Each sample's mapping file holds that sample's reads and no other sample's, whichever stems the
    /// pipeline gives the two samples. The stems come from the same helper the merge loop calls, and the
    /// merger writes the samples into one shared folder, as `mergeIlluminaPairsIfNeeded` does.
    func testEachSamplesMergedFileHoldsOnlyItsOwnReads() async throws {
        let bbmergeURL = try await ToolAvailability.require("bbmerge.sh", environment: "bbtools")
        let fragments = [
            InterleavedFASTQFixture.deterministicSequence(seed: 101, length: 150),
            InterleavedFASTQFixture.deterministicSequence(seed: 202, length: 150),
        ]
        var bundles: [URL] = []
        for (name, fragment) in zip(["S-1", "S--1"], fragments) {
            let bundle = try InterleavedFASTQFixture.writeBundle(
                named: name, in: root, pairCount: 6, naming: .casava,
                sequences: Self.overlappingPairs(of: fragment)
            )
            bundles.append(bundle.bundleURL)
        }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let samples = try await Pipeline.resolveIlluminaSampleInputsForTesting(from: bundles, stagingDirectory: staging)
        XCTAssertEqual(samples.map(\.sampleID), ["S-1", "S--1"])

        let mergeDirectory = root.appendingPathComponent("illumina-merged-fastqs", isDirectory: true)
        var mappingFiles: [URL] = []
        for sample in samples {
            let outcome = try await IlluminaAmpliconPairMerger.prepareForMapping(
                fastqURL: sample.fastqURL,
                bbmergeURL: bbmergeURL,
                workingDirectory: mergeDirectory,
                stem: Pipeline.mergeStemForTesting(for: sample),
                threads: 2
            )
            XCTAssertEqual(outcome.disposition, .merged, sample.sampleID)
            mappingFiles.append(outcome.mappingFASTQURL)
        }

        let names = mappingFiles.map { $0.lastPathComponent.lowercased() }
        XCTAssertEqual(Set(names).count, 2, "the two samples must write two mapping files, got \(names)")
        for index in samples.indices {
            let records = try await InterleavedFASTQFixture.readRecords(at: mappingFiles[index])
            XCTAssertFalse(records.isEmpty, "\(samples[index].sampleID) has merged reads")
            for record in records {
                let own = fragments[index].contains(record.sequence)
                    || fragments[index].contains(Self.reverseComplement(record.sequence))
                XCTAssertTrue(own, "\(samples[index].sampleID) holds a read that is not its own: \(record.sequence)")
            }
        }
    }
}
