// ClassifierReadIDListFlaggedConformanceTests.swift - Read-ID lists of selections whose BAM holds secondary or supplementary records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane IDPINS. Each test here is red until lane EXTRACT-FLAGS lands. BIO's ruling on the review of lane NVD
// (reviews/NVD.md R1, S1) is that classifier extraction passes `-F 0x404` to `samtools fastq`, which replaces the
// default 0x900, so secondary (0x100) and supplementary (0x800) records reach the FASTQ. The lists here are what
// `samtools view -F 0xD04` gives, the mapped primary records that are not duplicates, the mask the "Unique Reads"
// count uses and the mask EXTRACT-FLAGS gives extraction. Today the extraction writes more:
//
// - TaxTriage, sample SRR35517705, NC_074583.1. 993 records for the same 960 read names where the list holds 983. The
//   ten extra records are supplementary alignments, hard-clipped to keep 35 to 52 bases, so the FASTQ holds each of ten
//   reads twice and one copy is a fragment. The read names are the same, only records are extra.
// - EsViritu and NVD, the sarscov2 markers BAM, which holds one secondary, one supplementary and one duplicate record,
//   named `synthetic_sec_1`, `synthetic_sup_1` and `synthetic_dup_1`. 199 records for 102 read names where the list
//   holds 197 for 100. The two extra read names are `synthetic_sec_1` and `synthetic_sup_1`. The duplicate is left out
//   by both masks. NAO-MGS has no case here, since the BAM its import writes holds no secondary or supplementary
//   record.
//
// The selections in `ClassifierReadIDListConformanceTests` hold none of these records and pass today.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class ClassifierReadIDListFlaggedConformanceTests: XCTestCase {
    private typealias Support = ClassifierReadIDListSupport

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-read-id-flagged")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    /// The `minimap2` BAM of the SRR35517705 TaxTriage fixture holds ten supplementary records on NC_074583.1, each
    /// next to a primary record of its own read, 993 records for 983 primary ones.
    func testTaxTriageExtractionLeavesOutSupplementaryRecords() async throws {
        try await Support.requireTool(.samtools)
        let folder = try Support.copyFixtureFolder("taxtriage-mini", into: root, named: "taxtriage-mini")
        let names = try await Support.extract(
            .taxtriage,
            result: folder,
            [ClassifierRowSelector(sampleId: "SRR35517705", accessions: ["NC_074583.1"], taxIds: [])],
            to: root.appendingPathComponent("out/taxtriage.fastq")
        )
        Support.assertMatches(names, try Support.list(named: "taxtriage-SRR35517705-NC_074583.1"), "TaxTriage")
    }

    /// The sarscov2 markers BAM as the BAM of a single-sample EsViritu result.
    func testEsVirituExtractionLeavesOutSecondarySupplementaryAndDuplicateRecords() async throws {
        try await Support.requireTool(.samtools)
        let folder = try Support.makeResultFolder(in: root, named: "esviritu-markers")
        try Support.place(
            bam: Support.fixture("sarscov2/test.paired_end.sorted.markers.bam"),
            at: "markers_temp/markers.sorted.bam",
            in: folder
        )
        let names = try await Support.extract(
            .esviritu,
            result: folder,
            [ClassifierRowSelector(sampleId: nil, accessions: ["MT192765.1"], taxIds: [])],
            to: root.appendingPathComponent("out/esviritu.fastq")
        )
        Support.assertMatches(names, try Support.list(named: "esviritu-sarscov2-markers-MT192765.1"), "EsViritu")
    }

    /// The sarscov2 markers BAM as the BAM of an NVD sample.
    func testNvdExtractionLeavesOutSecondarySupplementaryAndDuplicateRecords() async throws {
        try await Support.requireTool(.samtools)
        let folder = try Support.makeResultFolder(in: root, named: "nvd-markers")
        try Support.place(
            bam: Support.fixture("sarscov2/test.paired_end.sorted.markers.bam"), at: "bam/S1.filtered.bam", in: folder
        )
        let names = try await Support.extract(
            .nvd,
            result: folder.appendingPathComponent("hits.sqlite"),
            [ClassifierRowSelector(sampleId: "S1", accessions: ["MT192765.1"], taxIds: [])],
            to: root.appendingPathComponent("out/nvd.fastq")
        )
        Support.assertMatches(names, try Support.list(named: "nvd-sarscov2-markers-MT192765.1"), "NVD")
    }
}
