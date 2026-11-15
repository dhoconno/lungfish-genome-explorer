// IlluminaMergeStemCollisionTests.swift - Two Illumina samples never share a staged or merged file name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Illumina amplicon path stages each sample under `<stem>.sample-prefixed.fastq` and hands the
// pair merger a stem, which names `<stem>.for-mapping.fastq` in one folder that every sample of the
// run shares. Two samples that reach one stem write one file, and a genotype is then called from the
// other sample's reads. These cases assert stems and names only and run no bbmerge. The conformance
// class beside this one runs the real tool.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class IlluminaMergeStemCollisionTests: XCTestCase {
    private typealias Pipeline = ONTBarcodeDemuxGenotypingPipeline
    private static let stagedSuffix = ".sample-prefixed.fastq"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("illumina-merge-stem-collision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The sample inputs the Illumina path builds for `inputs`, in a fresh staging folder.
    private func resolve(_ inputs: [URL]) async throws -> [Pipeline.IlluminaSampleInput] {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return try await Pipeline.resolveIlluminaSampleInputsForTesting(from: inputs, stagingDirectory: staging)
    }

    /// FASTQ text with one 8 bp read for each name in `reads`.
    private static func fastqText(_ reads: [String]) -> String {
        reads.map { "@\($0)\nACGTACGT\n+\nIIIIIIII\n" }.joined()
    }

    /// A `.lungfishfastq` bundle called `name` that holds one read for each name in `reads`.
    private func makeBundle(named name: String, reads: [String]) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.fastqText(reads).write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// A loose gzip FASTQ called `name` in the folder `folder`, so that two names which differ only
    /// in case never share a folder, as they would on a case-insensitive volume.
    private func makeGzipFASTQ(named name: String, inFolder folder: String, reads: [String]) async throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = root.appendingPathComponent("plain-\(folder).fastq")
        try Self.fastqText(reads).write(to: plain, atomically: true, encoding: .utf8)
        let gzipped = directory.appendingPathComponent(name)
        try await SystemToolProbe.gzip(plain, to: gzipped)
        return gzipped
    }

    /// The stem a sample's staged file carries, read from the file name.
    private func stagedStem(of sample: Pipeline.IlluminaSampleInput) -> String {
        let name = sample.prefixedFASTQURL.lastPathComponent
        XCTAssertTrue(name.hasSuffix(Self.stagedSuffix), "\(name) must end in \(Self.stagedSuffix)")
        return name.hasSuffix(Self.stagedSuffix) ? String(name.dropLast(Self.stagedSuffix.count)) : name
    }

    // MARK: - Cases

    /// Case A. `A/Sample_1.fastq.gz` and `B/sample_1.fastq.gz` give the IDs `Sample_1_fastq` and
    /// `sample_1_fastq`. APFS and exFAT fold case, so two staged names that differ only in case are
    /// one file, and the second sample's reads would overwrite the first's before any merge.
    func testStagedNamesOfIDsThatDifferOnlyInCaseDifferOnceCaseIsIgnored() async throws {
        let upper = try await makeGzipFASTQ(named: "Sample_1.fastq.gz", inFolder: "A", reads: ["rA1", "rA2"])
        let lower = try await makeGzipFASTQ(named: "sample_1.fastq.gz", inFolder: "B", reads: ["rB1"])

        let samples = try await resolve([upper, lower])

        XCTAssertEqual(samples.map(\.sampleID), ["Sample_1_fastq", "sample_1_fastq"], "reads stay tagged by each file's own ID")
        XCTAssertEqual(samples.map(\.readCount), [2, 1], "no sample's reads are lost")
        let staged = samples.map { $0.prefixedFASTQURL.lastPathComponent.lowercased() }
        XCTAssertEqual(Set(staged).count, 2, "staged names must differ once case is ignored, got \(staged)")
    }

    /// Case B. The IDs `S-1` and `S--1` stay distinct, and `safeFilenameStem` folds both to `S-1`.
    /// Staging already gives the second sample `S-1-2`. The merge must take that stem, or both samples
    /// write one `<stem>.for-mapping.fastq` and the first sample's mapping file holds the second's reads.
    func testMergeStemOfEachSampleIsItsStagedStemAndTheTwoDiffer() async throws {
        let first = try makeBundle(named: "S-1", reads: ["rA1", "rA2"])
        let second = try makeBundle(named: "S--1", reads: ["rB1"])

        let samples = try await resolve([first, second])

        XCTAssertEqual(samples.map(\.sampleID), ["S-1", "S--1"])
        let stagedStems = samples.map { stagedStem(of: $0) }
        XCTAssertEqual(stagedStems, ["S-1", "S-1-2"], "staging keeps the names it gives today")
        let mergeStems = samples.map { Pipeline.mergeStemForTesting(for: $0) }
        XCTAssertEqual(mergeStems, stagedStems, "each merge stem must be its sample's staged stem")
        XCTAssertEqual(Set(mergeStems.map { $0.lowercased() }).count, 2, "the two merge stems must differ, got \(mergeStems)")
    }

    /// Case C, the pin. IDs that share no stem keep the staged names and merge stems they have today,
    /// so no file name of an ordinary run moves.
    func testOrdinarySampleIDsKeepTheirStagedNamesAndMergeStems() async throws {
        let bundles = [
            try makeBundle(named: "LF2871", reads: ["r1"]),
            try makeBundle(named: "Sample 2", reads: ["r2"]),
            try makeBundle(named: "Plate-3_B", reads: ["r3"]),
        ]

        let samples = try await resolve(bundles)

        XCTAssertEqual(samples.map(\.sampleID), ["LF2871", "Sample_2", "Plate-3_B"])
        XCTAssertEqual(samples.map { $0.prefixedFASTQURL.lastPathComponent }, [
            "LF2871.sample-prefixed.fastq", "Sample_2.sample-prefixed.fastq", "Plate-3_B.sample-prefixed.fastq",
        ])
        XCTAssertEqual(samples.map { Pipeline.mergeStemForTesting(for: $0) }, ["LF2871", "Sample_2", "Plate-3_B"])
    }
}
