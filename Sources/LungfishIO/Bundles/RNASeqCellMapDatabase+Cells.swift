// RNASeqCellMapDatabase+Cells.swift - The sample and barcode of every cell of a cell map (Phase 5.5 lane CM-SELECT-CLI)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `rnaseq cell-map select` writes one line for each drawn cell in cell order with the parent's sample id and barcode, and
// the membership function returns the cells of each sample. Both read every cell's sample and barcode once, in one
// ordered read on the call's own handle, as `cellTotals()` reads the totals.

import Foundation

extension RNASeqCellMapDatabase {
    /// The `samples.sample` number and the barcode of every cell, in cell order. A cell the table does not hold reads
    /// sample 0 and an empty barcode.
    public func cellKeys() throws -> (sample: ContiguousArray<UInt32>, barcode: [String]) {
        try Self.withHandle(url) { db in
            let count = try Self.rows(db, "SELECT count(*) FROM cells", []) { Self.int($0, 0) }.first ?? 0
            var samples = ContiguousArray<UInt32>(repeating: 0, count: count)
            var barcodes = [String](repeating: "", count: count)
            try Self.step(db, "SELECT cell, sample, barcode FROM cells ORDER BY cell", []) { statement in
                let cell = Self.int(statement, 0)
                guard cell >= 1, cell <= count else {
                    throw RNASeqResultError.invalidTable(path: RNASeqCellMap.filename, reason: "the cells table names the cell \(cell), which the map does not hold")
                }
                samples[cell - 1] = UInt32(clamping: Self.int(statement, 1))
                barcodes[cell - 1] = Self.text(statement, 2)
            }
            return (samples, barcodes)
        }
    }
}
