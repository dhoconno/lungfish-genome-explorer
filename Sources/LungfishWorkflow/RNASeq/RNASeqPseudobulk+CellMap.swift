// RNASeqPseudobulk+CellMap.swift - The cell map of a selection's pseudobulk and its record (Phase 5.5 lane CM-SELECT-CLI)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `rnaseq pseudobulk <result> --labels <table> --cell-map <cell map>` sums a selection's table through the existing pass.
// `--cell-map` names the map the table came from, so the record leads from the sum to the map and, through the table's
// own record, to the polygon or the labels (`docs/formats/rnaseq-cell-map.md`, Pseudobulk of a selection). The result
// adds no manifest key and stays at schema 1.

import Foundation
import LungfishCore
import LungfishIO

extension RNASeqPseudobulk {
    /// W7 of `SCR/inv/UX.md` U-A6, which the CLI prints before its summary line when `--cell-map` is given (5.5 S3, W1).
    public static let selectionWords = "Cells picked from this picture differ in the genes that drew it, so testing a selection against the rest "
        + "finds those genes by construction. Compare samples or animals within one selection."

    /// The cell map that a run names, by its folder and the sha256 of its manifest.
    public struct CellMapInput: Equatable, Sendable {
        public var url: URL
        public var name: String
        public var manifestSHA256: String
    }

    /// Refuses a `--cell-map` that is not a cell map, one whose files differ from its manifest, and one made from another
    /// result than `result`, in that order, before any matrix is read.
    public static func checkCellMap(_ cellMap: URL, result: URL) throws -> CellMapInput {
        let (manifest, manifestSHA) = try RNASeqCellMapSelect.checkCellMap(cellMap)
        let given = try RNASeqResultBundle.sha256Hex(fileAt: RNASeqResultBundle.manifestURL(in: result))
        let recorded = manifest.parent?.manifestSHA256 ?? RNASeqResultBundle.notRecordedText
        guard recorded == given else {
            // `parent.path` is written from the folder that holds the cell map (`RNASeqResultWriter.parentPointer`).
            let parent = manifest.parent.map { cellMap.deletingLastPathComponent().appendingPathComponent($0.path).standardizedFileURL.path }
                ?? RNASeqResultBundle.notRecordedText
            throw RNASeqPseudobulkRefusal.cellMapOfAnotherParent(
                cellMap: cellMap.lastPathComponent, recorded: recorded, result: result.lastPathComponent, given: given, parent: parent)
        }
        return CellMapInput(url: cellMap, name: manifest.name, manifestSHA256: manifestSHA)
    }

    /// The record's facts with the cell map added beside the result and the table.
    public static func facts(_ facts: [String: ParameterValue], cellMap: CellMapInput) -> [String: ParameterValue] {
        var facts = facts
        facts["cellMap"] = .string(cellMap.name)
        facts["cellMapManifestSHA256"] = .string(cellMap.manifestSHA256)
        return facts
    }
}
