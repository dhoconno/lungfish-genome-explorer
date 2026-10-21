// TaxonomyMergedViewPercentTests.swift - The merged Kraken2 view shows each sample's row as that sample's own percent
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.35, KR-MERGE-PCT (BIO-R1 item 5). The merged tree gave each sample's node the share of all the
// picked samples' reads and no direct reads. The node's tooltip promises the sample's own classified percent, and the
// exported table now gives it, so the view and the file agree on what every row means.

import XCTest
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class TaxonomyMergedViewPercentTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "TaxonomyMergedViewPercent")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// The two samples of BIO-R1 item 2. Sample A has 80 reads, a root with 70 clade and 30 direct reads, one species
    /// of 40 reads and 10 unclassified. Sample B has 60 reads, a root with 50 clade and 30 direct reads, one species of
    /// 20 reads and 10 unclassified. Each species carries the percentage Kraken2 reports for it.
    private func makeBatch(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows: [Kraken2ClassificationRow] = []
        for (sample, name, taxId, clade, total) in [
            ("sample-A", "Species A", 40, 70, 80), ("sample-B", "Species B", 20, 50, 60),
        ] {
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                readsDirect: 30, readsClade: clade, percentage: Double(clade) * 100 / Double(total),
                parentTaxId: nil, depth: 0
            ))
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: name, taxId: taxId, rank: "S", rankDisplayName: "Species",
                readsDirect: clade - 30, readsClade: clade - 30, percentage: Double(clade - 30) * 100 / Double(total),
                parentTaxId: 1, depth: 1
            ))
        }
        try Kraken2Database.create(
            at: folder.appendingPathComponent("kraken2.sqlite"),
            rows: rows,
            metadata: [
                "total_reads_sample-A": "80", "total_reads_sample-B": "60",
                "unclassified_reads_sample-A": "10", "unclassified_reads_sample-B": "10",
            ]
        )
    }

    /// With both samples picked, a sample's node counts the reads Kraken2 assigned to the root alone and shows its
    /// classified reads as a fraction of that sample's own reads, and a taxon below it keeps its database percentage.
    func testTheMergedViewShowsEachSamplesOwnPercent() throws {
        let parityCase = Kraken2TableExportCLIGUIParityReplayTests.Case.databaseEverySample
        try makeBatch(in: Kraken2TableExportCLIGUIParityReplayTests.folderURL(in: scratch, parityCase))
        let view = try Kraken2TableExportCLIGUIParityReplayTests.configuredView(scratch, parityCase)
        let tree = try XCTUnwrap(view.tree)
        XCTAssertEqual(tree.root.readsClade, 140, "Root stays the sum of every picked sample's reads")
        XCTAssertEqual(tree.root.children.map(\.name), ["sample-A", "sample-B"])
        let sampleA = try XCTUnwrap(tree.root.children.first)
        let sampleB = try XCTUnwrap(tree.root.children.last)

        XCTAssertEqual(sampleA.readsClade, 70)
        XCTAssertEqual(sampleA.readsDirect, 30)
        XCTAssertEqual(sampleA.fractionClade, 70.0 / 80.0, accuracy: 1e-9)
        XCTAssertEqual(sampleA.fractionDirect, 30.0 / 80.0, accuracy: 1e-9)
        XCTAssertEqual(sampleB.readsClade, 50)
        XCTAssertEqual(sampleB.readsDirect, 30)
        XCTAssertEqual(sampleB.fractionClade, 50.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(sampleB.fractionDirect, 30.0 / 60.0, accuracy: 1e-9)

        let speciesA = try XCTUnwrap(sampleA.children.first { $0.name == "Species A" })
        XCTAssertEqual(speciesA.fractionClade, (40.0 * 100 / 80.0) / 100, accuracy: 1e-9)
        let speciesB = try XCTUnwrap(sampleB.children.first { $0.name == "Species B" })
        XCTAssertEqual(speciesB.fractionClade, (20.0 * 100 / 60.0) / 100, accuracy: 1e-9)
    }
}
