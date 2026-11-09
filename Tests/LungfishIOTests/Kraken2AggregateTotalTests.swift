// Kraken2AggregateTotalTests.swift - a Kraken 2 sample reads the batch total only in a one-sample database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane RIDERS-RESULT, row KRAKEN-TOTAL-FALLBACK (S3, BIO). `fetchTree(sample:)` took the aggregate
// `total_reads` and `unclassified_reads` for any sample with no key of its own, so one sample of a hand-made or
// half-rebuilt multi-sample database showed the batch's totals under its own name. The aggregate belongs to a sample
// only when the database holds that one sample. A sample with no total of its own has no recorded total (0), and
// `TaxonTree.unclassifiedReads` must not go negative for it.

import XCTest
@testable import LungfishIO

final class Kraken2AggregateTotalTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kraken2AggregateTotalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A root and one virus taxon holding all of `reads` classified reads, for `sample`.
    private func rows(sample: String, reads: Int) -> [Kraken2ClassificationRow] {
        [
            Kraken2ClassificationRow(sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                                     readsDirect: 0, readsClade: reads, percentage: 100, parentTaxId: nil, depth: 0),
            Kraken2ClassificationRow(sample: sample, taxonName: "Virus sp.", taxId: 10, rank: "S", rankDisplayName: "Species",
                                     readsDirect: reads, readsClade: reads, percentage: 100, parentTaxId: 1, depth: 1),
        ]
    }

    /// Sample A records its own totals (100 reads, 80 classified, 20 unclassified). Sample B has 40 classified reads and
    /// no key of its own. The aggregate keys hold the batch (A 100 plus B 60 gives 160 reads, 40 unclassified).
    /// Red at the base, where B shows the batch's 160 reads and 40 unclassified reads.
    func testFetchTreeDoesNotBorrowTheAggregateTotalForOneOfSeveralSamples() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Kraken2Database.create(
            at: dir.appendingPathComponent("kraken2.sqlite"),
            rows: rows(sample: "A", reads: 80) + rows(sample: "B", reads: 40),
            metadata: [
                "total_reads_A": "100", "unclassified_reads_A": "20",
                "total_reads": "160", "unclassified_reads": "40",
            ]
        )

        let b = try db.fetchTree(sample: "B")
        XCTAssertEqual(b.totalReads, 0, "B has no total of its own, and the batch total of 160 is not B's")
        XCTAssertEqual(b.unclassifiedReads, 0, "B has no unclassified count of its own, and the batch's 40 is not B's")
        XCTAssertNil(b.unclassifiedNode, "no unclassified node is drawn from the batch's count")
        XCTAssertEqual(b.classifiedReads, 40, "the classified reads are B's own rows")

        let a = try db.fetchTree(sample: "A")
        XCTAssertEqual(a.totalReads, 100, "A keeps its own total")
        XCTAssertEqual(a.unclassifiedReads, 20, "A keeps its own unclassified count")
    }

    /// A database of one sample may hold only the aggregate keys, which are then that sample's. A pin that passes at
    /// the base and after the fix.
    func testFetchTreeKeepsTheAggregateTotalForAOneSampleDatabase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Kraken2Database.create(
            at: dir.appendingPathComponent("kraken2.sqlite"),
            rows: rows(sample: "S", reads: 40),
            metadata: ["total_reads": "100", "unclassified_reads": "60"]
        )

        let tree = try db.fetchTree(sample: "S")
        XCTAssertEqual(tree.totalReads, 100)
        XCTAssertEqual(tree.unclassifiedReads, 60)
        XCTAssertEqual(tree.classifiedReads, 40)
    }

    /// A total of 0 is no recorded total, and 0 less 40 classified reads is not an unclassified count. Red at the base,
    /// where the unclassified count is -40.
    func testFetchTreeWithNoRecordedTotalHasNoNegativeUnclassifiedReads() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Kraken2Database.create(
            at: dir.appendingPathComponent("kraken2.sqlite"), rows: rows(sample: "S", reads: 40), metadata: [:]
        )

        let tree = try db.fetchTree(sample: "S")
        XCTAssertEqual(tree.totalReads, 0)
        XCTAssertEqual(tree.classifiedReads, 40)
        XCTAssertEqual(tree.unclassifiedReads, 0, "a tree with no recorded total has no negative unclassified reads")
        XCTAssertEqual(tree.unclassifiedFraction, 0)
    }
}
