// MappingReferenceCountTextTests.swift - The summary-bar clause for reference sequences a mapping left out
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

/// The words of the count label and its help (UX ruling Q-B2, section 3).
final class MappingReferenceCountTextTests: XCTestCase {
    func testStatesAlignedOfTotalWhenSequencesWereLeftOut() throws {
        let text = try XCTUnwrap(
            MappingReferenceCountText.make(referenceCount: 905_628, unalignedReferenceCount: 905_534, storedRowCount: 94)
        )

        XCTAssertEqual(text.label, "94 of 905,628 reference sequences have alignments")
        XCTAssertEqual(text.help, "905,534 reference sequences have no alignments in this mapping and are not listed.")
    }

    func testSingularAndZeroForms() throws {
        let oneAligned = try XCTUnwrap(
            MappingReferenceCountText.make(referenceCount: 3, unalignedReferenceCount: 2, storedRowCount: 1)
        )
        XCTAssertEqual(oneAligned.label, "1 of 3 reference sequences has alignments")
        XCTAssertEqual(oneAligned.help, "2 reference sequences have no alignments in this mapping and are not listed.")

        let oneLeftOut = try XCTUnwrap(
            MappingReferenceCountText.make(referenceCount: 3, unalignedReferenceCount: 1, storedRowCount: 2)
        )
        XCTAssertEqual(oneLeftOut.label, "2 of 3 reference sequences have alignments")
        XCTAssertEqual(oneLeftOut.help, "1 reference sequence has no alignments in this mapping and is not listed.")

        let noneAligned = try XCTUnwrap(
            MappingReferenceCountText.make(referenceCount: 3, unalignedReferenceCount: 3, storedRowCount: 0)
        )
        XCTAssertEqual(noneAligned.label, "0 of 3 reference sequences have alignments")
        XCTAssertEqual(noneAligned.help, "3 reference sequences have no alignments in this mapping and are not listed.")
    }

    /// Unknown counts, nothing left out, a one-sequence reference and counts
    /// the stored rows contradict all show nothing.
    func testNoClauseWithoutCountsOrOmissions() {
        let cases: [(total: Int?, unaligned: Int?, rows: Int)] = [
            (nil, nil, 905_628), (3, nil, 3), (nil, 1, 2), (3, 0, 3), (1, 1, 0), (5, 2, 2), (3, 4, 0),
        ]
        for (total, unaligned, rows) in cases {
            XCTAssertNil(
                MappingReferenceCountText.make(referenceCount: total, unalignedReferenceCount: unaligned, storedRowCount: rows),
                "\(String(describing: total)), \(String(describing: unaligned)), \(rows)"
            )
        }
    }
}
