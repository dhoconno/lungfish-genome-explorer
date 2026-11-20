// RNASeqPseudobulk+Labels.swift - The label table of rnaseq pseudobulk and its groups (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The table is tab-separated with a header, plain or gzip, with `barcode`, `label` and, for a result of two or more
// samples, `sample`. A barcode matches `cells.barcode` as given. Every line is checked before the pass reads a matrix.

import Foundation
import LungfishIO

extension RNASeqPseudobulk {
    /// One sample's cells as `cells.sqlite` lists them, each barcode with its column in the matrix, from 1.
    struct SampleCells {
        var name: String
        var count: Int
        var columnOfBarcode: [String: Int]
    }

    /// Every group in column order, kept and dropped alike, and for each sample the group of each column or -1.
    struct LabelAssignment {
        var groups: [Group]
        var groupOfCell: [[Int]]
    }
}
