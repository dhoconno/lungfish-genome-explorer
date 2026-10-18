// TaxTriageBatchManifestUniqueReadsTests.swift - The bytes the TaxTriage viewer writes when a batch's unique reads arrive
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.01 M3 (DEC Q-B9, S31 note 1). The viewer merges the unique reads of its flat table into
// `taxtriage-batch-manifest.json`, so the next open shows them without a BAM pass. These tests pin the bytes of
// that write before its load, merge and save move off the main actor.

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

    /// The load, merge and save of `updateBatchManifestUniqueReads`, which is private and runs on the main actor at
    /// the base of M3, written out as it reads there.
    private func writeAsTheViewerDoes(_ uniqueReadsByKey: [String: Int], batchURL: URL) async throws {
        var manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadTaxTriageBatchManifest(from: batchURL))
        for i in manifest.cachedRows.indices {
            let row = manifest.cachedRows[i]
            let key = "\(row.sample)\t\(row.organism)"
            if let uniqueReads = uniqueReadsByKey[key] {
                let safeUnique = ClassifierUniqueReads.normalizedOrFloor(stored: uniqueReads, readCount: row.reads)
                manifest.cachedRows[i] = TaxTriageBatchManifest.CachedRow(
                    sample: row.sample, organism: row.organism, tassScore: row.tassScore, reads: row.reads,
                    uniqueReads: safeUnique, confidence: row.confidence, coverageBreadth: row.coverageBreadth,
                    coverageDepth: row.coverageDepth, abundance: row.abundance
                )
            }
        }
        try MetagenomicsBatchResultStore.saveTaxTriageBatchManifest(manifest, to: batchURL)
    }

    func testTheUniqueReadsWriteKeepsTheManifestBytes() async throws {
        try MetagenomicsBatchResultStore.saveTaxTriageBatchManifest(Self.saved, to: root)

        try await writeAsTheViewerDoes(Self.uniqueReadsByKey, batchURL: root)

        let url = root.appendingPathComponent(TaxTriageBatchManifest.filename)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [TaxTriageBatchManifest.filename])
    }
}
