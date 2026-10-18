// BatchTableDisplayOrder.swift - Sorts batch table rows into display order
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

/// Sorts a ``BatchTableView``'s rows into display order.
///
/// The table's comparator alone decides the order, and the result always equals
/// `rows.sorted(by:)` with that comparator, the stable sort the table ran before.
/// Two shortcuts make a large table cheap to sort.
///
/// - Rows that already arrive in display order come back unchanged, after one
///   comparison per adjacent pair, because the stable sort would not move them.
/// - Presort keys, built once per row, arrange the rows first, and the comparator
///   then checks the arrangement pair by pair. Where a key disagrees, the comparator
///   sorts the arrangement again, which stays close to linear because the standard
///   sort merges the runs the keys already ordered. A key costs time, never order.
enum BatchTableDisplayOrder {

    static func sorted<Row>(
        _ rows: [Row],
        ascending: Bool,
        presortKeys: () -> [String]?,
        by areInIncreasingOrder: (Row, Row) -> Bool
    ) -> [Row] {
        if !zip(rows, rows.dropFirst()).contains(where: { areInIncreasingOrder($1, $0) }) {
            return rows
        }
        guard let keys = presortKeys(), keys.count == rows.count else {
            return rows.sorted(by: areInIncreasingOrder)
        }
        func inOrder(_ earlier: Int, _ later: Int) -> Bool {
            areInIncreasingOrder(rows[earlier], rows[later])
        }

        // The standard sort is stable, so rows with equal keys keep their input order.
        var order = Array(rows.indices)
        if ascending {
            order.sort { keys[$0] < keys[$1] }
        } else {
            order.sort { keys[$0] > keys[$1] }
        }

        // A stable sort keeps rows the comparator ties in their input order, so each
        // adjacent pair must be in order, and a tied pair in input order as well.
        var needsSort = false
        for (earlier, later) in zip(order, order.dropFirst()) where !inOrder(earlier, later) {
            if inOrder(later, earlier) {
                needsSort = true
                break
            }
            // Tied rows with different keys, which the keys put out of input order.
            if earlier > later { return rows.sorted(by: areInIncreasingOrder) }
        }
        if needsSort {
            order.sort(by: inOrder)
            for (earlier, later) in zip(order, order.dropFirst()) where earlier > later && !inOrder(earlier, later) {
                return rows.sorted(by: areInIncreasingOrder)
            }
        }
        return order.map { rows[$0] }
    }
}
