// RNASeqPseudobulkRefusal.swift - The words of each refusal of rnaseq pseudobulk (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Every refusal comes before anything is written (`docs/formats/rnaseq-bundle.md`, Pseudobulk), and its words name the
// file and what to do.

import Foundation

public enum RNASeqPseudobulkRefusal: Error, Equatable, LocalizedError, Sendable {
    case bulkResult(name: String)
    case checksumsDiffer(name: String, paths: [String])
    case noCells(name: String)
    case missingColumn(file: String, column: String)
    case noSampleColumn(file: String, samples: Int)
    case lineCells(file: String, line: Int, cells: Int, header: Int)
    case emptyLabel(file: String, line: Int)
    case unknownSample(file: String, line: Int, sample: String, known: [String])
    case barcodeTwice(file: String, line: Int, firstLine: Int, sample: String, barcode: String)
    case barcodesNotHeld(file: String, count: Int, first: [String])
    case columnClash(column: String, first: String, second: String)
    case noGroupLeft(file: String)
    case outputExists(path: String)
    case notAResultName(name: String)
    case noOutputFolder(path: String)
    /// `--cell-map` names a cell map whose parent is not the given result (Phase 5.5 lane CM-SELECT-CLI).
    case cellMapOfAnotherParent(cellMap: String, recorded: String, result: String, given: String, parent: String)

    public var errorDescription: String? {
        switch self {
        case .bulkResult(let name):
            return "\(name) is a bulk result. rnaseq pseudobulk sums the cells of a single-cell result, "
                + "such as one that import rnaseq made from Cell Ranger or STARsolo folders."
        case .checksumsDiffer(let name, let paths):
            let what = paths.count == 1 ? "The file \(paths[0]) of \(name) differs from the sha256 that its manifest lists"
                : "The files \(Self.list(paths)) of \(name) differ from the sha256 values that its manifest lists"
            return what + ", so the result changed after LGE wrote it. Import the tool's folders again into a new result."
        case .noCells(let name):
            return "\(name) lists no matrices or no cells.sqlite, so it holds no cells to sum. Import the Cell Ranger or STARsolo folders again."
        case .missingColumn(let file, let column):
            return "\(file) has no \(column) column. Its header needs barcode and label, and sample when the result holds two or more samples."
        case .noSampleColumn(let file, let samples):
            return "The result holds \(samples) samples and \(file) has no sample column, so a barcode cannot name its sample. "
                + "Add a sample column that holds the sample ids of samples.tsv."
        case .lineCells(let file, let line, let cells, let header):
            return "Line \(line) of \(file) has \(Self.count(cells, "column")) and the header has \(header). "
                + "Give each line one cell for each column of the header."
        case .emptyLabel(let file, let line):
            return "Line \(line) of \(file) has an empty label. Give the cell a label, or leave its line out so the cell has none."
        case .unknownSample(let file, let line, let sample, let known):
            return "Line \(line) of \(file) names the sample \(sample), which the result does not hold. Its samples are \(Self.list(known))."
        case .barcodeTwice(let file, let line, let firstLine, let sample, let barcode):
            return "Line \(line) of \(file) lists the barcode \(barcode) of sample \(sample) again, after line \(firstLine). List each cell once."
        case .barcodesNotHeld(let file, let count, let first):
            return "\(file) lists \(Self.count(count, "barcode")) that the result does not hold, such as \(first.joined(separator: ", ")). "
                + "Barcodes match as given, so a STARsolo barcode is bare and a 10x barcode ends in -1."
        case .columnClash(let column, let first, let second):
            return "The groups \(first) and \(second) would both be the column \(column). "
                + "Rename a label so that each sample and label gives its own column."
        case .noGroupLeft(let file):
            return "No group of \(file) holds \(RNASeqPseudobulk.minimumCells) or more cells, so there is no column to write. "
                + "A group is one sample and one label."
        case .outputExists(let path):
            return "\(path) already exists. Choose a new name for the result."
        case .notAResultName(let name):
            return "--output names a new folder whose name ends in .lungfishrnaseq, such as pbmc-pseudobulk.lungfishrnaseq, and not \(name)."
        case .noOutputFolder(let path):
            return "No folder at \(path) to write the result in. Create it or choose another output."
        case .cellMapOfAnotherParent(let cellMap, let recorded, let result, let given, let parent):
            return "\(cellMap) was made from the single-cell result whose manifest has sha256 \(recorded), and \(result) has \(given). "
                + "Give the result the cell map was made from, \(parent)."
        }
    }

    static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }

    static func list(_ words: [String]) -> String {
        words.count <= 1 ? words.joined() : words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
    }
}
