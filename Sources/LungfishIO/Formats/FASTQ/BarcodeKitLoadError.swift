// BarcodeKitLoadError.swift - Errors from loading a custom barcode kit definition
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum BarcodeKitLoadError: LocalizedError, Sendable, Equatable {
    case noBarcodeRows
    case invalidSequence(row: Int, id: String, value: String)
    case invalidSecondarySequence(row: Int, id: String, value: String)
    case ambiguousThirdColumn(row: Int, id: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .noBarcodeRows:
            return "Barcode definition contains no barcode rows. Use CSV or TSV with at least two columns: id,sequence; for example: FLD0001,GTATCGTCGT or FLD0001<TAB>GTATCGTCGT."
        case .invalidSequence(let row, let id, let value):
            return "Barcode definition row \(row) (\(id)): the sequence column holds '\(value)', which is not a nucleotide sequence. Columns are id,sequence[,secondary_sequence][,sample_name]."
        case .invalidSecondarySequence(let row, let id, let value):
            return "Barcode definition row \(row) (\(id)): the secondary sequence column holds '\(value)', which is not a nucleotide sequence. If this column holds sample names, name it sample_name in the header line."
        case .ambiguousThirdColumn(let row, let id, let value):
            return "Barcode definition row \(row) (\(id)): the third column holds '\(value)', which is not a nucleotide sequence. Without a header line the third column is the secondary (dual-index) barcode. Put sample names in the fourth column (id,sequence,,sample_name) or add a header line naming the columns (id,sequence,sample_name)."
        }
    }
}
