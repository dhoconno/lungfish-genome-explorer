// BlastSavedSearchRowContigListTests.swift - A saved search's contig list matches in any order
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN2, item 1. A multi-contig search joins its IDs in selection or lookup order, and TaxTriage ranks
// its accessions by read support, which can change between launches. The same contigs in another order are the same search.

import Foundation
import XCTest
@testable import LungfishCore

final class BlastSavedSearchRowContigListTests: XCTestCase {
    private let result = URL(fileURLWithPath: "/tmp/reopen2/Project.lungfish/Analyses/run")
    private let recordURL = URL(fileURLWithPath: "/tmp/reopen2/search/blast-result.json")

    private func row(contig: String?) -> BlastSavedSearchRow {
        BlastSavedSearchRow(sourceResultURL: result, sample: "S1", taxId: 7, contig: contig)
    }

    private func lineage(contig: String?) -> BlastSubmissionRecord.Lineage {
        .init(sourceResult: result.path, sample: "S1", taxId: 7, contig: contig)
    }

    func testAContigListMatchesInAnyOrder() {
        XCTAssertTrue(row(contig: "NC_1,NC_2,NC_3").isSource(of: lineage(contig: "NC_3,NC_1,NC_2"), recordAt: recordURL))
    }

    func testAContigListWithOneMoreOrOneOtherIDDoesNotMatch() {
        let key = row(contig: "NC_1,NC_2")
        XCTAssertFalse(key.isSource(of: lineage(contig: "NC_1,NC_2,NC_3"), recordAt: recordURL), "one more ID")
        XCTAssertFalse(key.isSource(of: lineage(contig: "NC_1"), recordAt: recordURL), "one fewer ID")
        XCTAssertFalse(key.isSource(of: lineage(contig: "NC_1,NC_3"), recordAt: recordURL), "one other ID")
    }

    func testASingleContigMatchesOnlyItself() {
        XCTAssertTrue(row(contig: "NC_1").isSource(of: lineage(contig: "NC_1"), recordAt: recordURL))
        XCTAssertFalse(row(contig: "NC_1").isSource(of: lineage(contig: "NC_2"), recordAt: recordURL))
        XCTAssertFalse(row(contig: "NC_1").isSource(of: lineage(contig: nil), recordAt: recordURL))
        XCTAssertFalse(row(contig: nil).isSource(of: lineage(contig: "NC_1"), recordAt: recordURL))
        XCTAssertTrue(row(contig: nil).isSource(of: lineage(contig: nil), recordAt: recordURL))
    }
}
