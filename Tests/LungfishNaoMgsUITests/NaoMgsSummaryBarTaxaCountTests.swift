// NaoMgsSummaryBarTaxaCountTests.swift - The header counts each taxon once across samples
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishNaoMgsUI

/// NAOMGS-TAXA-COUNT-WORDS (first walk, WN1). The Taxa card of a NAO-MGS result read `7 taxa` beside `Unique Taxa 4`
/// in the Summary, because it counted sample-taxon rows and not taxa. Both summary-bar routes count distinct taxon IDs.
@MainActor
final class NaoMgsSummaryBarTaxaCountTests: XCTestCase {
    /// Two samples, seven sample-taxon rows and four taxa.
    private static let pairs: [(sample: String, taxId: Int)] = [
        ("sample-A", 11), ("sample-A", 12), ("sample-A", 13), ("sample-A", 14),
        ("sample-B", 11), ("sample-B", 12), ("sample-B", 13),
    ]

    func testHeaderCountsEachTaxonOnceAcrossSamples() throws {
        // The route that reads the cached summary rows.
        let rows = Self.pairs.map { Self.summaryRow(sample: $0.sample, taxId: $0.taxId) }
        let cached = NaoMgsSummaryBar()
        cached.update(cachedRows: rows, manifest: nil, selectedSamples: [])
        XCTAssertEqual(Self.taxaValue(of: cached), "4 taxa", "seven rows over four taxa read 4 taxa")
        cached.update(cachedRows: rows, manifest: nil, selectedSamples: ["sample-B"])
        XCTAssertEqual(Self.taxaValue(of: cached), "3 taxa", "the header follows the selected samples")
        let sharedTaxon = [Self.summaryRow(sample: "sample-A", taxId: 11), Self.summaryRow(sample: "sample-B", taxId: 11)]
        cached.update(cachedRows: sharedTaxon, manifest: nil, selectedSamples: [])
        XCTAssertEqual(Self.taxaValue(of: cached), "1 taxon", "one taxon found in two samples reads in the singular")

        // The route that reads the database.
        let directory = try TestTempDirectory.make(prefix: "naomgs-taxa-count")
        defer { TestTempDirectory.cleanup(directory) }
        let hits = Self.pairs.enumerated().map { Self.hit(sample: $1.sample, taxId: $1.taxId, read: $0) }
        let database = try NaoMgsDatabase.create(at: directory.appendingPathComponent("hits.sqlite"), hits: hits)
        let fromDatabase = NaoMgsSummaryBar()
        fromDatabase.update(database: database, manifest: nil, selectedSamples: ["sample-A", "sample-B"])
        XCTAssertEqual(Self.taxaValue(of: fromDatabase), "4 taxa", "the database route counts each taxon once too")
    }

    private static func taxaValue(of bar: NaoMgsSummaryBar) -> String? {
        bar.cards.first { $0.label == "Taxa" }?.value
    }

    private static func summaryRow(sample: String, taxId: Int) -> NaoMgsTaxonSummaryRow {
        NaoMgsTaxonSummaryRow(
            sample: sample, taxId: taxId, name: "Taxon \(taxId)", hitCount: 2, uniqueReadCount: 2,
            avgIdentity: 99, avgBitScore: 200, avgEditDistance: 1, pcrDuplicateCount: 0, accessionCount: 1,
            topAccessions: ["NC_\(taxId).1"], bamPath: nil, bamIndexPath: nil
        )
    }

    private static func hit(sample: String, taxId: Int, read: Int) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample, seqId: "read-\(read)", taxId: taxId,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100,
            refStart: read * 100, refEnd: read * 100 + 100,
            readSequence: String(repeating: "A", count: 100), readQuality: String(repeating: "I", count: 100),
            subjectSeqId: "NC_\(taxId).1", subjectTitle: "Taxon \(taxId) genome",
            bitScore: 200, eValue: 1e-50, percentIdentity: 99, editDistance: 1,
            fragmentLength: 300, isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
    }
}
