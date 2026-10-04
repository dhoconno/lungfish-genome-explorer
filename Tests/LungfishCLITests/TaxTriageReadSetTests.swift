// TaxTriageReadSetTests.swift - lungfish-cli taxtriage run hands TaxTriage the pairs and every read of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner decision 1 of 2026-10-03 (docs/contracts/READ-PAIRING.md): pairs that
// were not merged reach a tool as pairs whenever it can take them, and nothing
// is dropped. TaxTriage reads pairs only as the samplesheet's fastq_1 and
// fastq_2, one file each, so a mixed sample or several chunks run as one file of
// single reads. Read names say what each read is, as in ReadSetFixtures.

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class TaxTriageReadSetTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-read-sets")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Samples TaxTriage already runs, pinned

    func testASingleEndRootIsOneFile() throws {
        XCTAssertEqual(try reads(of: fixtures.singleRoot), [["s1", "s2", "s3"]])
    }

    /// The pipeline splits a strictly interleaved file into R1 and R2 as it
    /// does today, so the sample reaches it as one interleaved file.
    func testAnInterleavedRootIsOneInterleavedFile() throws {
        XCTAssertEqual(try reads(of: fixtures.interleavedRoot), [["i1/1", "i1/2", "i2/1", "i2/2"]])
    }

    func testAMixedRootIsOneFileOfEveryRead() throws {
        XCTAssertEqual(try reads(of: fixtures.mixedRoot), [["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"]])
    }

    // MARK: - Every read reaches TaxTriage

    /// L5b. Before: R1 only, `p1/1` and `p2/1`, so the mates were never seen.
    /// After: fastq_1 holds R1 and fastq_2 holds R2.
    func testAPairedDerivativeIsHandedBothMates() throws {
        XCTAssertEqual(try reads(of: fixtures.pairedDerivative), [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
    }

    /// L5c. Before: the first file by name, `merged.fastq`, three of the five
    /// reads. After: one file of all five reads.
    func testAMergeDerivativeIsHandedEveryRead() throws {
        let files = try reads(of: fixtures.mergeDerivative)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.sorted(), ["u1/1", "u1/2", "x1", "x2", "x3"])
    }

    /// L5d. Before: the first file by name, `repaired_R1.fastq`, two of the
    /// five reads. After: one file of all five reads.
    func testARepairDerivativeIsHandedEveryRead() throws {
        let files = try reads(of: fixtures.repairDerivative)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.sorted(), ["o1", "r1/1", "r1/2", "r2/1", "r2/2"])
    }

    /// L4. Before: the command refused a bundle of two chunks. After: one
    /// file of the three reads of both chunks.
    func testAChunkedRootIsHandedEveryChunkAsOneFile() throws {
        XCTAssertEqual(try reads(of: fixtures.chunkedRoot), [["c1", "c2", "c3"]])
    }

    // MARK: - Helpers

    /// The record names of each file TaxTriage reads for one `--input <bundle>`,
    /// fastq_1 then fastq_2.
    private func reads(of bundle: URL) throws -> [[String]] {
        let fastq1 = try TaxTriageCommand.RunSubcommand.resolveReadsFile(for: bundle)
        return [try ReadSetFixtures.readNames(in: fastq1)]
    }
}
