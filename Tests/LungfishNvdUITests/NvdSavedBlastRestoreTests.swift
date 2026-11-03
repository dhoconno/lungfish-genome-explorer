// NvdSavedBlastRestoreTests.swift - An NVD row shows its own saved BLAST search again
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN (BLAST-RESULT-NOT-REOPENED, S2, O115). An NVD row matches on its result, its sample, its contig
// and its adjusted tax ID. A contig with no adjusted tax ID records none, and its row matches a record that names none.

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishNvdUI

@MainActor
final class NvdSavedBlastRestoreTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var vc: NvdResultViewController!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        saved = try SavedBlastSearchProject()
    }

    override func tearDown() async throws {
        vc = nil
        saved?.remove()
        try await super.tearDown()
    }

    func testClassifierRowRestoresOnlyItsOwnResultsSavedSearch() async throws {
        try saved.saveRecord(rid: "RID-A", sourceResult: "nvd-A", sample: "sample-1", taxId: 1234, contig: "contig_1", age: 100)
        try saved.saveRecord(rid: "RID-B", sourceResult: "nvd-B", sample: "sample-1", taxId: 1234, contig: "contig_1")
        try openResult(adjustedTaxid: "1234")

        try select(sample: "sample-1")

        let shown = await waitUntil { self.vc.resultActions.lastBlastResult != nil }
        XCTAssertTrue(shown, "the row's saved search comes back")
        XCTAssertEqual(vc.resultActions.lastBlastResult?.rid, "RID-A", "the newer search of result B is not this row's")
        XCTAssertFalse(vc.resultActions.isBlastDrawerOpen, "a restored search does not open the pane")
    }

    func testTheSameContigNameInTwoSamplesShowsEachSamplesOwnRecord() async throws {
        try saved.saveRecord(rid: "RID-S-1", sourceResult: "nvd-A", sample: "sample-1", taxId: 1234, contig: "contig_1")
        try saved.saveRecord(rid: "RID-S-2", sourceResult: "nvd-A", sample: "sample-2", taxId: 1234, contig: "contig_1")
        try openResult(adjustedTaxid: "1234")

        try select(sample: "sample-2")
        let second = await waitUntil { self.vc.resultActions.lastBlastResult?.rid == "RID-S-2" }
        XCTAssertTrue(second, "sample 2's row shows sample 2's search")

        try select(sample: "sample-1")
        let first = await waitUntil { self.vc.resultActions.lastBlastResult?.rid == "RID-S-1" }
        XCTAssertTrue(first, "sample 1's row shows sample 1's search")
    }

    /// A contig with no adjusted tax ID sends 0, which the plan records as no taxon. A record of another contig or of a
    /// taxon is not this row's.
    func testARowWithNoTaxIDMatchesOnItsResultSampleAndContig() async throws {
        try saved.saveRecord(rid: "RID-TAXON", sourceResult: "nvd-A", sample: "sample-1", taxId: 1234, contig: "contig_1")
        try saved.saveRecord(rid: "RID-OTHER", sourceResult: "nvd-A", sample: "sample-1", taxId: nil, contig: "contig_9")
        try saved.saveRecord(rid: "RID-OWN", sourceResult: "nvd-A", sample: "sample-1", taxId: nil, contig: "contig_1", age: 100)
        try openResult(adjustedTaxid: "")

        try select(sample: "sample-1")

        let shown = await waitUntil { self.vc.resultActions.lastBlastResult != nil }
        XCTAssertTrue(shown, "the row's saved search comes back")
        XCTAssertEqual(vc.resultActions.lastBlastResult?.rid, "RID-OWN")
    }

    private func openResult(adjustedTaxid: String) throws {
        let bundle = try saved.result("nvd-A")
        let samples = ["sample-1", "sample-2"]
        let hits = samples.map { Self.hit(sample: $0, adjustedTaxid: adjustedTaxid) }
        let database = try NvdDatabase.create(
            at: bundle.appendingPathComponent("nvd.sqlite"),
            hits: hits,
            samples: samples.map {
                NvdSampleMetadata(
                    sampleId: $0, bamPath: "\($0).bam", fastaPath: "\($0).fasta",
                    totalReads: 1000, contigCount: 1, hitCount: 1
                )
            }
        )
        let manifest = NvdManifest(
            experiment: "exp-1", sampleCount: 2, contigCount: 2, hitCount: 2,
            blastDbVersion: "db", snakemakeRunId: "run-1", sourceDirectoryPath: bundle.path,
            samples: samples.map {
                NvdSampleSummary(
                    sampleId: $0, contigCount: 1, hitCount: 1, totalReads: 1000,
                    bamRelativePath: "\($0).bam", bamIndexRelativePath: "\($0).bam.bai",
                    fastaRelativePath: "\($0).fasta"
                )
            },
            cachedTopContigs: nil
        )
        vc = NvdResultViewController()
        isolateLayouts(vc)
        _ = vc.view
        vc.configure(database: database, manifest: manifest, bundleURL: bundle)
    }

    private func select(sample: String) throws {
        for row in 0..<vc.testOutlineView.numberOfRows {
            vc.testSelectOutlineRow(row)
            if vc.testSelectedOutlineContigSamples() == [sample] { return }
        }
        XCTFail("no row of \(sample)")
    }

    private static func hit(sample: String, adjustedTaxid: String) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-1", blastTask: "blastn", sampleId: sample, qseqid: "contig_1",
            qlen: 8, sseqid: "NC_000001.1", stitle: "Reference",
            taxRank: "species", length: 8, pident: 100, evalue: 0, bitscore: 50,
            sscinames: "Example virus", staxids: "1234", blastDbVersion: "db", snakemakeRunId: "run-1",
            mappedReads: 1_000, totalReads: 1000, statDbVersion: "stats-1", adjustedTaxid: adjustedTaxid,
            adjustmentMethod: "dominant", adjustedTaxidName: "Example virus", adjustedTaxidRank: "species",
            hitRank: 1, readsPerBillion: 10_000
        )
    }
}
