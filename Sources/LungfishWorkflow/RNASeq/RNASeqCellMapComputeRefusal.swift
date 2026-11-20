// RNASeqCellMapComputeRefusal.swift - The words of each refusal of rnaseq cell-map compute (Phase 5.5 lane CM-COMPUTE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Each way `rnaseq cell-map compute` stops before it writes a cell map, in words that say what to do.
public enum RNASeqCellMapComputeRefusal: Error, LocalizedError, Equatable {
    case memory(RNASeqCellMapCompute.MemoryPrediction)
    case seed(Int)
    case threads(Int)
    case notMatrixMarket(sample: String, format: String)
    case inputChanged(file: String, name: String)
    case scriptChanged(found: String)
    case notInstalled
    case scriptFailed(exitCode: Int32, line: String)
    case recordUnreadable
    case record(field: String, found: String, expected: String)
    case tableForm
    case memoryStop(message: String)

    public var errorDescription: String? {
        switch self {
        case .memory(let prediction):
            // Ruling ADJ-SC-EMBED item 6, the words UX reads once (vote S-2 condition 7).
            return "Not started: this cell map is predicted to need about \(Self.bytes(prediction.peak)) of memory at its peak "
                + "(\(RNASeqCellMapImportRefusal.count(prediction.cells, "cell")), "
                + "\(RNASeqCellMapImportRefusal.number(prediction.entries)) stored entries), more than 40% of this Mac's "
                + "\(Self.bytes(prediction.physicalMemory)) (\(Self.bytes(prediction.bound))). This Mac can compute about "
                + "\(RNASeqCellMapImportRefusal.count(prediction.cellsAtThisDepth, "cell")) of this depth. Choose fewer cells, use a Mac with more memory, "
                + "or compute the embedding elsewhere and bring it in with Import Embedding."
        case .seed(let seed):
            return "The seed \(seed) is not offered. The route's pin, its tests and its record check hold seed 0, so run again with --seed 0."
        case .threads(let threads):
            return "--threads must be 1 or more, not \(threads)."
        case .notMatrixMarket(let sample, let format):
            return "The matrix of \(sample) is stored as \(format), and the route reads only Matrix Market matrices. Import the result again from its Matrix Market folder."
        case .inputChanged(let file, let name):
            return "\(file) of \(name) does not have the sha256 its manifest names, so it changed after the result was written. "
                + "Import the result again, then compute the cell map."
        case .scriptChanged(let found):
            return "The route's script in this build has sha256 \(found), not \(RNASeqCellMapCompute.scriptSHA256). Install LGE again."
        case .notInstalled:
            return "The Single-Cell Analysis pack is not installed. Install it in Plugin Manager, then compute the cell map again."
        case .scriptFailed(let exitCode, let line):
            return "The route stopped with exit code \(exitCode) and wrote no cell map. Its last line was: \(line)"
        case .recordUnreadable:
            return "The route wrote no record that LGE can read, so no cell map was written."
        case .record(let field, let found, let expected):
            return "The route's record says \(field) is \(found), where a route run says \(expected). No cell map was written."
        case .tableForm:
            return "The route's cells.tsv does not start with the columns sample, barcode, x, y and cluster, so no cell map was written."
        case .memoryStop(let message):
            return message
        }
    }

    /// Bytes in the binary units macOS shows for a Mac's memory, written as GB with one decimal: 16 GiB reads "16.0 GB".
    static func bytes(_ value: UInt64) -> String {
        String(format: "%.1f GB", Double(value) / 1_073_741_824)
    }
}
