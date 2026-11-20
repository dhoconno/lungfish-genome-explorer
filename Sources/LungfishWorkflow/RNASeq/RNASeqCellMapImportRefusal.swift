// RNASeqCellMapImportRefusal.swift - The words of each refusal of rnaseq cell-map import (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The words are those of `docs/formats/rnaseq-cell-map.md`, What the import refuses. The cases the page marks "as
// pseudobulk" throw `RNASeqPseudobulkRefusal` itself, so both commands say the same thing for the same case. Every refusal
// comes before anything is written.

import Foundation

public enum RNASeqCellMapImportRefusal: Error, Equatable, LocalizedError, Sendable {
    case outputInsideResult(result: String)
    case unreadable(file: String, reason: String)
    case unknownForm(file: String)
    case noEmbedding
    case noLabelColumn(file: String, column: String)
    case methodForm(text: String)
    case methodTwice(embedding: String)
    case methodNoEmbedding(name: String, embeddings: [String])
    case oneDimension(file: String, name: String, column: String, joiner: Character)
    case gap(file: String, name: String, present: Int, missing: Int, joiner: Character)
    case columnTwice(file: String, column: String)
    case nameTwice(what: String, name: String, first: String, second: String)
    case tableNameTwice(first: String, second: String, fileName: String)
    case quote(file: String, line: Int)
    case notFinite(file: String, line: Int, text: String, column: String)
    case tenXManySamples(file: String, samples: Int)
    case suffix(file: String, sample: String, wouldMatch: Int, of: Int, suffix: RNASeqCellMapImport.BarcodeSuffix)
    case notHeld(file: String, count: Int, first: [String])
    case otherCounts(file: String, name: String, tool: String)
    case changedWhileRead(file: String)

    public var errorDescription: String? {
        switch self {
        case .outputInsideResult(let result):
            return "--output names a folder inside the result \(result). LGE never writes inside a result, "
                + "so choose a folder beside it, such as the project's Analyses folder."
        case .unreadable(let file, let reason):
            return "\(file) cannot be read as text, \(reason). Give the file as the tool wrote it."
        case .unknownForm(let file):
            return "\(file) is not LGE's table or one of 10x's files. LGE's table has a barcode column, "
                + "and 10x's files start Barcode,TSNE-1,TSNE-2 or Barcode,Cluster."
        case .noEmbedding:
            return "No given file holds an embedding. Give LGE's table with columns such as umap_1 and umap_2, or one of 10x's projection.csv files."
        case .noLabelColumn(let file, let column):
            return "\(file) has no column \(column), which --label-column names."
        case .methodForm(let text):
            return "--method takes <embedding>=<name>, such as umap=UMAP, with no tab or line break, and not \(text)."
        case .methodTwice(let embedding):
            return "--method names the embedding \(embedding) twice. Give one method for each embedding."
        case .methodNoEmbedding(let name, let embeddings):
            return "--method names the embedding \(name), which no given file holds. The embeddings are \(RNASeqPseudobulkRefusal.list(embeddings))."
        case .oneDimension(let file, let name, let column, let joiner):
            return "\(file) gives the embedding \(name) only the column \(column). An embedding needs \(name)\(joiner)1 and \(name)\(joiner)2 at least. "
                + "Name a column of labels with --label-column."
        case .gap(let file, let name, let present, let missing, let joiner):
            return "\(file) gives \(name)\(joiner)\(present) and no \(name)\(joiner)\(missing). Number the columns of an embedding from 1 with no gap."
        case .columnTwice(let file, let column):
            return "Line 1 of \(file) names the column \(column) twice. Give each column its own name."
        case .nameTwice(let what, let name, let first, let second):
            return "The \(what) \(name) comes from both \(first) and \(second). Give each \(what) its own name."
        case .tableNameTwice(let first, let second, let fileName):
            return "The label sets \(first) and \(second) would both be written as labels/\(fileName). Rename one of them."
        case .quote(let file, let line):
            return "Line \(line) of \(file) holds a quote, and 10x's files hold none. Give the file as Cell Ranger wrote it."
        case .notFinite(let file, let line, let text, let column):
            return "Line \(line) of \(file) gives \(text) in \(column), which is not a finite decimal number. Give a number such as -12.5 or 3.2e-2."
        case .tenXManySamples(let file, let samples):
            return "\(file) is one of 10x's files, which name no sample, and the result holds \(Self.number(samples)) samples. "
                + "Give 10x's files for a result of one sample, or write LGE's table with a sample column."
        case .suffix(let file, let sample, let wouldMatch, let of, let suffix):
            let (way, ask) = suffix == .drop ? ("dropped", "To drop -1 from every given barcode") : ("added", "To add -1 to every given barcode")
            return "No barcode of \(file) matches sample \(sample) as given, and \(Self.number(wouldMatch)) of its \(Self.count(of, "barcode")) "
                + "would match with -1 \(way). LGE changes no barcode unless asked. \(ask), run again with --barcode-suffix \(suffix.rawValue)."
        case .notHeld(let file, let count, let first):
            return "\(file) lists \(Self.count(count, "barcode")) that the result does not hold, such as \(first.joined(separator: ", ")). "
                + "Barcodes match as given unless --barcode-suffix changed them, so a STARsolo barcode is bare and a 10x barcode ends in -1. "
                + "To leave them out and import the rest, run again with --skip-barcodes-not-held, and the record counts them."
        case .otherCounts(let file, let name, let tool):
            return "\(file) is 10x's analysis of Cell Ranger's counts, and \(name) holds the counts of \(tool). "
                + "To import it all the same, run again with --other-counts, and the record and the view then say computed on other counts."
        case .changedWhileRead(let file):
            return "\(file) changed while LGE read it, so the copy kept under source/ is not the file that was checked. "
                + "Run the import again once the file no longer changes."
        }
    }

    /// A whole number with its thousands marked, such as 1,221.
    static func number(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped += "," }
            grouped.append(digit)
        }
        return (value < 0 ? "-" : "") + grouped
    }

    /// "1 barcode" or "<n> barcodes".
    static func count(_ value: Int, _ noun: String) -> String { "\(number(value)) \(noun)\(value == 1 ? "" : "s")" }
}
