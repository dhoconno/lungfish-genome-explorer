// TaxTriageBatchManifestUniqueReadsTests.swift - The bytes the TaxTriage viewer writes when a batch's unique reads arrive
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.01 M3 (DEC Q-B9, S31 note 1). The viewer merges the unique reads of its flat table into
// `taxtriage-batch-manifest.json`, so the next open shows them without a BAM pass. These tests pin the bytes of
// that write, whose load, merge and save run off the main actor since M3, and the order of writes in a row.

import XCTest
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageBatchManifestUniqueReadsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try TestTempDirectory.make(prefix: "taxtriage-manifest-unique-reads")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
        try super.tearDownWithError()
    }

    private static let influenza = "Influenza A virus (A/California/07/2009(H1N1))"

    private static func row(_ sample: String, _ organism: String, reads: Int, uniqueReads: Int?) -> TaxTriageBatchManifest.CachedRow {
        TaxTriageBatchManifest.CachedRow(
            sample: sample, organism: organism, tassScore: 0.5, reads: reads, uniqueReads: uniqueReads,
            confidence: "high", coverageBreadth: nil, coverageDepth: 2.5, abundance: nil
        )
    }

    /// Two rows the table names, one at 80 and one at 0 that floors to 1 read, and two it does not name.
    private static let saved = TaxTriageBatchManifest(
        createdAt: Date(timeIntervalSince1970: 0),
        sampleCount: 2,
        sampleIds: ["S1", "S2"],
        cachedRows: [
            row("S1", influenza, reads: 120, uniqueReads: nil),
            row("S1", "Escherichia coli", reads: 7, uniqueReads: 3),
            row("S2", "Human betaherpesvirus 5", reads: 40, uniqueReads: 12),
            row("S2", "Escherichia coli", reads: 0, uniqueReads: nil),
        ]
    )

    /// The flat table's unique reads, keyed by sample and organism, one of them for no row of the manifest.
    private static let uniqueReadsByKey = [
        "S1\t\(influenza)": 80,
        "S2\tHuman betaherpesvirus 5": 0,
        "S3\tNot in the manifest": 9,
    ]

    private static let expected = """
        {
          "cachedRows" : [
            {
              "confidence" : "high",
              "coverageDepth" : 2.5,
              "organism" : "Influenza A virus (A\\/California\\/07\\/2009(H1N1))",
              "reads" : 120,
              "sample" : "S1",
              "tassScore" : 0.5,
              "uniqueReads" : 80
            },
            {
              "confidence" : "high",
              "coverageDepth" : 2.5,
              "organism" : "Escherichia coli",
              "reads" : 7,
              "sample" : "S1",
              "tassScore" : 0.5,
              "uniqueReads" : 3
            },
            {
              "confidence" : "high",
              "coverageDepth" : 2.5,
              "organism" : "Human betaherpesvirus 5",
              "reads" : 40,
              "sample" : "S2",
              "tassScore" : 0.5,
              "uniqueReads" : 1
            },
            {
              "confidence" : "high",
              "coverageDepth" : 2.5,
              "organism" : "Escherichia coli",
              "reads" : 0,
              "sample" : "S2",
              "tassScore" : 0.5
            }
          ],
          "createdAt" : "1970-01-01T00:00:00Z",
          "sampleCount" : 2,
          "sampleIds" : [
            "S1",
            "S2"
          ]
        }
        """

    /// The viewer's write, awaited through the task it returns.
    private func writeAsTheViewerDoes(_ uniqueReadsByKey: [String: Int], batchURL: URL) async throws {
        let viewer = TaxTriageResultViewController()
        viewer.batchGroupURL = batchURL
        viewer.batchFlatTableView.uniqueReadsByKey = uniqueReadsByKey
        let write = try XCTUnwrap(viewer.updateBatchManifestUniqueReads())
        await write.value
    }

    func testTheUniqueReadsWriteKeepsTheManifestBytes() async throws {
        try MetagenomicsBatchResultStore.saveTaxTriageBatchManifest(Self.saved, to: root)

        try await writeAsTheViewerDoes(Self.uniqueReadsByKey, batchURL: root)

        let url = root.appendingPathComponent(TaxTriageBatchManifest.filename)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [TaxTriageBatchManifest.filename])
    }

    /// Each write waits for the one before it, so the table's last values are the ones on disk.
    func testWritesInARowLandInTheirOrder() async throws {
        try MetagenomicsBatchResultStore.saveTaxTriageBatchManifest(Self.saved, to: root)
        let viewer = TaxTriageResultViewController()
        viewer.batchGroupURL = root
        var writes: [Task<Void, Never>] = []
        for uniqueReads in [5, 6, 7, 80] {
            viewer.batchFlatTableView.uniqueReadsByKey = ["S1\t\(Self.influenza)": uniqueReads]
            writes.append(try XCTUnwrap(viewer.updateBatchManifestUniqueReads()))
        }
        for write in writes {
            await write.value
        }

        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadTaxTriageBatchManifest(from: root))
        XCTAssertEqual(manifest.cachedRows.map(\.uniqueReads), [80, 3, 12, nil], "the last write wins")
    }

    func testAViewerWithNoBatchFolderWritesNothing() {
        XCTAssertNil(TaxTriageResultViewController().updateBatchManifestUniqueReads())
    }
}
