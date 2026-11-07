// BarcodeKitLoadError.swift - Errors from loading a custom barcode kit definition
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum BarcodeKitLoadError: LocalizedError, Sendable, Equatable {
    case noBarcodeRows
    case invalidSequence(row: Int, id: String, value: String)
    case invalidSecondarySequence(row: Int, id: String, value: String)
    case ambiguousThirdColumn(row: Int, id: String, value: String)
    /// The `# kit:` line names a kit this version does not know.
    case unknownKit(id: String)
    /// Two `# kit:` lines name different kits.
    case conflictingKitLines(first: String, second: String)
    /// A row's index count differs from the barcodes of the kit the `# kit:` line names.
    case kitIndexMismatch(kit: String, id: String, kitHasSecondary: Bool)
    /// The definition's bytes are not UTF-8 text, such as a CSV that a spreadsheet saved as Windows-1252.
    case notUTF8(name: String)

    public var errorDescription: String? {
        switch self {
        case .notUTF8(let name):
            return "The barcode definition \(name) is not UTF-8 text, so Lungfish cannot read its names. Open it in a spreadsheet or text editor, save it as CSV UTF-8, then run again."
        case .noBarcodeRows:
            return "Barcode definition contains no barcode rows. Use CSV or TSV with at least two columns: id,sequence; for example: FLD0001,GTATCGTCGT or FLD0001<TAB>GTATCGTCGT."
        case .invalidSequence(let row, let id, let value):
            return "Barcode definition row \(row) (\(id)): the sequence column holds '\(value)', which is not a nucleotide sequence. Columns are id,sequence[,secondary_sequence][,sample_name]."
        case .invalidSecondarySequence(let row, let id, let value):
            return "Barcode definition row \(row) (\(id)): the secondary sequence column holds '\(value)', which is not a nucleotide sequence. If this column holds sample names, name it sample_name in the header line."
        case .ambiguousThirdColumn(let row, let id, let value):
            return "Barcode definition row \(row) (\(id)): the third column holds '\(value)', which is not a nucleotide sequence. Without a header line the third column is the secondary (dual-index) barcode. Put sample names in the fourth column (id,sequence,,sample_name) or add a header line naming the columns (id,sequence,sample_name)."
        case .unknownKit(let id):
            return "The barcode definition's # kit line names the kit '\(id)', and this version of Lungfish has no kit with that ID. Choose a kit this version knows, or remove the # kit line so the definition is read as its own kit."
        case .conflictingKitLines(let first, let second):
            return "The barcode definition names two kits in its # kit lines, '\(first)' and '\(second)'. Keep only the line of the kit the barcodes came from."
        case .kitIndexMismatch(let kit, let id, let kitHasSecondary):
            if kitHasSecondary {
                return "The barcode definition names the kit \(kit), whose barcodes carry two indexes, but its row \(id) has no secondary sequence. Give the row its second index, or remove the # kit line."
            }
            return "The barcode definition names the kit \(kit), whose barcodes carry one sequence, but its row \(id) has a secondary sequence. Remove the secondary sequence, or remove the # kit line."
        }
    }
}
