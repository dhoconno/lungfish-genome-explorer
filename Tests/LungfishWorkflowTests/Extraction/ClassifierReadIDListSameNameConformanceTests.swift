// ClassifierReadIDListSameNameConformanceTests.swift - An extraction keeps both mates of an SRA-named read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane FASTQ-SAME-NAME, ruling R1 of the IDPINS review (reviews/IDPINS.md). `samtools fastq` writes one record
// for consecutive records of one read name when neither carries READ1 or READ2, so an SRA-named read whose two mates were
// mapped as single reads lost a mate in the FASTQ, while the table's estimate (`samtools view -c`) and the read names
// both still held it. EsViritu and TaxTriage results from before the strict-interleave route, and any run today on a mixed
// input (an SRA run with a third file of unpaired reads), hold such BAMs, and the three fixtures below are of that kind:
// no primary record carries the paired flag and 5 to 28 names hold two records.
//
// The lists are what `samtools view -F 0xD04` gives for the selection, the tool run directly, and the extraction must
// write one FASTQ record for each of those records. The read names never moved (the first mate always survived), so
// each case fails on the record count alone: the base wrote 117 of 118, 29 of 30 and 14 of 16.
//
// It runs the managed samtools, so its name holds Conformance and it skips without it unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class ClassifierReadIDListSameNameConformanceTests: XCTestCase {
    private typealias Support = ClassifierReadIDListSupport

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-read-id-same-name")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    /// The viewer's selection of two viruses of the EsViritu sample SRR35517702, the references `OM695287.1` and
    /// `MF094130.1`. The BAM holds 118 mapped primary records for 113 read names, five names with both mates mapped as
    /// single reads. The base wrote 117 records.
    func testEsVirituExtractionKeepsBothMatesOfAnSraName() async throws {
        try await Support.requireTool(.samtools)
        let folder = try Support.copyFixtureFolder("esviritu-mini/SRR35517702", into: root, named: "esviritu-SRR35517702")
        let names = try await Support.extract(
            .esviritu,
            result: folder,
            [ClassifierRowSelector(sampleId: nil, accessions: ["OM695287.1", "MF094130.1"], taxIds: [])],
            to: root.appendingPathComponent("out/esviritu.fastq")
        )
        let list = try Support.list(named: "esviritu-SRR35517702-OM695287.1-MF094130.1")
        Support.assertMatches(names, list, "EsViritu")
        XCTAssertEqual(list.records, 118, "the frozen list is the 118 records of the selection")
        XCTAssertEqual(list.ids.count, 113, "the frozen list is the 113 read names of the selection")
        XCTAssertEqual(names.count - Set(names).count, 5, "five read names hold both of their mates")
    }

    /// The viewer's selection of the reference `NC_045512.2` of two TaxTriage samples. SRR35517702 holds 30 mapped
    /// primary records for 25 read names (the base wrote 29) and SRR35517705 holds 16 for 11 (the base wrote 14).
    func testTaxTriageExtractionKeepsBothMatesOfAnSraName() async throws {
        try await Support.requireTool(.samtools)
        let folder = try Support.copyFixtureFolder("taxtriage-mini", into: root, named: "taxtriage-mini")
        let cases: [(sample: String, list: String, records: Int, unique: Int)] = [
            ("SRR35517702", "taxtriage-SRR35517702-NC_045512.2", 30, 25),
            ("SRR35517705", "taxtriage-SRR35517705-NC_045512.2", 16, 11),
        ]
        for testCase in cases {
            let names = try await Support.extract(
                .taxtriage,
                result: folder,
                [ClassifierRowSelector(sampleId: testCase.sample, accessions: ["NC_045512.2"], taxIds: [])],
                to: root.appendingPathComponent("out/taxtriage-\(testCase.sample).fastq")
            )
            let list = try Support.list(named: testCase.list)
            Support.assertMatches(names, list, "TaxTriage \(testCase.sample)")
            XCTAssertEqual(list.records, testCase.records, "\(testCase.list) holds the \(testCase.records) records")
            XCTAssertEqual(list.ids.count, testCase.unique, "\(testCase.list) holds the \(testCase.unique) read names")
            XCTAssertEqual(
                names.count - Set(names).count, testCase.records - testCase.unique,
                "TaxTriage \(testCase.sample) leaves a mate out of a name that holds two"
            )
        }
    }
}
