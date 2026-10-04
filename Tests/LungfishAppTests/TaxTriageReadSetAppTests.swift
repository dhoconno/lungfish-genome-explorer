// TaxTriageReadSetAppTests.swift - The TaxTriage launch hands the samplesheet the pairs and every read of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner decision 1 of 2026-10-03 (docs/contracts/READ-PAIRING.md): pairs that
// were not merged reach a tool as pairs whenever it can take them, and nothing
// is dropped. TaxTriage reads pairs only as the samplesheet's fastq_1 and
// fastq_2, one file each, so a mixed sample or several chunks run as one file of
// single reads. The launch resolves each sample, then `TaxTriagePipeline.run`
// splits a strictly interleaved file and writes the samplesheet rows these
// tests read. Read names say what each read is, as in ReadSetFixtures.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class TaxTriageReadSetAppTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-read-sets-app")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Samples TaxTriage already runs, pinned

    func testASingleEndRootIsOneSingleEndRow() async throws {
        let row = try await samplesheetRow(for: fixtures.singleRoot)
        XCTAssertEqual(row.fastq1, ["s1", "s2", "s3"])
        XCTAssertNil(row.fastq2)
    }

    /// The pipeline splits the interleaved file into R1 and R2, so the row is a pair.
    func testAnInterleavedRootBecomesAPairedRow() async throws {
        let row = try await samplesheetRow(for: fixtures.interleavedRoot)
        XCTAssertEqual(row.fastq1, ["i1/1", "i2/1"])
        XCTAssertEqual(row.fastq2, ["i1/2", "i2/2"])
    }

    func testAMixedRootIsOneSingleEndRowOfEveryRead() async throws {
        let row = try await samplesheetRow(for: fixtures.mixedRoot)
        XCTAssertEqual(row.fastq1, ["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"])
        XCTAssertNil(row.fastq2)
    }

    func testAPairedDerivativeIsOnePairedRow() async throws {
        let row = try await samplesheetRow(for: fixtures.pairedDerivative)
        XCTAssertEqual(row.fastq1, ["p1/1", "p2/1"])
        XCTAssertEqual(row.fastq2, ["p1/2", "p2/2"])
    }

    // MARK: - Every read reaches the samplesheet

    /// L5c. Before: fastq_1 was `merged.fastq` (x1 to x3) and fastq_2 was
    /// `unmerged_R1.fastq` (u1/1), so the mate u1/2 was dropped and u1/1
    /// stood in as a second mate of the merged reads. After: one single-end
    /// row of all five reads.
    func testAMergeDerivativeIsOneSingleEndRowOfEveryRead() async throws {
        let row = try await samplesheetRow(for: fixtures.mergeDerivative)
        XCTAssertEqual(row.fastq1.sorted(), ["u1/1", "u1/2", "x1", "x2", "x3"])
        XCTAssertNil(row.fastq2, "a mixed sample is not a pair")
    }

    /// L5d. Before: fastq_1 was `repaired_R1.fastq` and fastq_2 was
    /// `repaired_R2.fastq`, so the orphan o1 was dropped. After: one
    /// single-end row of all five reads.
    func testARepairDerivativeIsOneSingleEndRowOfEveryRead() async throws {
        let row = try await samplesheetRow(for: fixtures.repairDerivative)
        XCTAssertEqual(row.fastq1.sorted(), ["o1", "r1/1", "r1/2", "r2/1", "r2/2"])
        XCTAssertNil(row.fastq2, "a sample with an orphan is not a pair")
    }

    /// L4. Before: chunk one was fastq_1 and chunk two was fastq_2, a pair
    /// that never existed, and every other chunk was dropped. After: one
    /// single-end row of all three reads.
    func testAChunkedRootIsOneSingleEndRowOfEveryChunk() async throws {
        let row = try await samplesheetRow(for: fixtures.chunkedRoot)
        XCTAssertEqual(row.fastq1, ["c1", "c2", "c3"])
        XCTAssertNil(row.fastq2, "chunks of one run are not mates")
    }

    // MARK: - Helpers

    private struct Row {
        let fastq1: [String]
        let fastq2: [String]?
    }

    /// Resolves one sample through the app's TaxTriage launch, prepares it as
    /// `TaxTriagePipeline.run` does and reads its samplesheet row.
    private func samplesheetRow(for bundle: URL) async throws -> Row {
        let sample = TaxTriageSample(sampleId: "sample", fastq1: bundle)
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        )
        let resolved = try await AppDelegate().resolvedTaxTriageConfig(
            config,
            tempDirectory: root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true)
        )
        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(
            in: resolved,
            splitRoot: root.appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        )
        let entry = try XCTUnwrap(TaxTriagePipeline.samplesheetEntries(for: prepared.config).first)
        return Row(
            fastq1: try ReadSetFixtures.readNames(in: URL(fileURLWithPath: entry.fastq1Path)),
            fastq2: try entry.fastq2Path.map { try ReadSetFixtures.readNames(in: URL(fileURLWithPath: $0)) }
        )
    }
}
