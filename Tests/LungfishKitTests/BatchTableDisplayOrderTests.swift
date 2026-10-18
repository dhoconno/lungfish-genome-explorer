// BatchTableDisplayOrderTests.swift - Display order with presort keys
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

final class BatchTableDisplayOrderTests: XCTestCase {

    private struct Row: Equatable {
        let name: String
        let position: Int
    }

    /// Three rows named `chr1`, which tie and so keep their input order, names that
    /// differ only in case, leading zeros or punctuation, and names outside ASCII.
    private let rows = [
        "chr10", "chr2", "Chr2", "scaffold_9", "chr1", "contig-1", "chr02", "contig_1", "chr1",
        "contig.1", "\u{03A9}mega", "chrX", "chr1", "scaffold_10", "caf\u{00E9}", "cafe",
    ].enumerated().map { Row(name: $1, position: $0) }

    /// The comparator the reference record table uses for its sequence column.
    private func standardOrder(_ lhs: Row, _ rhs: Row, ascending: Bool) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    func testDisplayOrderEqualsTheStableComparatorSortWhateverTheKeys() {
        let keyings: [(label: String, key: (Row) -> String)] = [
            ("lowercased names", { $0.name.lowercased() }),
            ("reversed names", { String($0.name.reversed()) }),
            ("one key for every row", { _ in "" }),
            ("tied rows keyed against input order", { "\($0.name.lowercased())\(1_000 - $0.position)" }),
        ]
        for ascending in [true, false] {
            let expected = rows.sorted { standardOrder($0, $1, ascending: ascending) }
            for keying in keyings {
                let displayed = BatchTableDisplayOrder.sorted(
                    rows,
                    ascending: ascending,
                    presortKeys: { rows.map(keying.key) },
                    by: { standardOrder($0, $1, ascending: ascending) }
                )
                XCTAssertEqual(displayed, expected, "\(keying.label), ascending \(ascending)")
            }
            let unkeyed = BatchTableDisplayOrder.sorted(rows, ascending: ascending, presortKeys: { nil }) {
                standardOrder($0, $1, ascending: ascending)
            }
            XCTAssertEqual(unkeyed, expected, "no keys, ascending \(ascending)")
        }
    }

    func testRowsThatArriveInOrderAreNotSortedAgain() {
        let inOrder = rows.sorted { standardOrder($0, $1, ascending: true) }
        var keyBuilds = 0
        var comparisons = 0
        let displayed = BatchTableDisplayOrder.sorted(
            inOrder,
            ascending: true,
            presortKeys: {
                keyBuilds += 1
                return inOrder.map(\.name)
            },
            by: {
                comparisons += 1
                return standardOrder($0, $1, ascending: true)
            }
        )
        XCTAssertEqual(displayed, inOrder)
        XCTAssertEqual(keyBuilds, 0)
        XCTAssertEqual(comparisons, inOrder.count - 1)
    }

    /// With keys that agree with the comparator, the comparator confirms each adjacent
    /// pair once instead of sorting, which takes about n log n calls.
    func testAgreeingKeysCostOneComparisonPerAdjacentPair() {
        let shuffled = (0..<2_000).map { position in
            Row(name: "seq\((position * 7_919) % 2_000)", position: position)
        }
        var comparisons = 0
        let displayed = BatchTableDisplayOrder.sorted(
            shuffled,
            ascending: true,
            presortKeys: { shuffled.map { String(format: "seq%05d", Int($0.name.dropFirst(3)) ?? 0) } },
            by: {
                comparisons += 1
                return standardOrder($0, $1, ascending: true)
            }
        )
        XCTAssertEqual(displayed, shuffled.sorted { standardOrder($0, $1, ascending: true) })
        XCTAssertLessThan(comparisons, 2 * shuffled.count)
    }
}
