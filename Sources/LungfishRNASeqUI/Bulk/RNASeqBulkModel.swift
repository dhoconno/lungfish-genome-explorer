// RNASeqBulkModel.swift - What the bulk view of an RNA-seq result shows (Phase 5.4 lane RS-BULK-VIEW M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view shows what the CLI wrote and computes no number of its own (program plan 5.4). A count prints as the one
// writer printed it into the table's file, the gene facts come from `genes.tsv`, and every quality and correlation cell
// is the text that `lungfish-cli rnaseq quality` prints, from the same Workflow types.

import Foundation
import LungfishIO
import LungfishWorkflow
import Observation

/// One count table of the result, shown in its own tab. A masked table is never joined to the default one.
public struct RNASeqBulkTable: Equatable, Sendable {
    /// The table's path in the result, such as `counts/genes.counts.tsv`.
    public var path: String
    public var rows: RNASeqResultManifest.CountEntry.Rows
    public var column: RNASeqResultManifest.CountEntry.Column
    public var unit: RNASeqResultManifest.CountEntry.Unit
    public var table: RNASeqCountTable
    /// The rows that the search keeps, in the table's order.
    public internal(set) var visibleRows: [Int]
    /// For each row, its line in `genes.tsv`, or -1 when `genes.tsv` lists no such feature.
    var geneLine: [Int]
    /// For each row, the lowercased id and name joined by a tab, which the search reads.
    var searchKeys: [String]

    public var sampleIDs: [String] { table.sampleIDs }
    public var rowCount: Int { table.rows.count }

    /// The tab's title, such as Genes or Genes, masked.
    public var title: String {
        let what = rows == .gene ? "Genes" : "Transcripts"
        return column == .masked ? "\(what), masked" : what
    }

    /// The unit in the words of `rnaseq quality`, such as estimated counts.
    public var unitWords: String { RNASeqQualitySummary.unitWords(unit) }

    /// The line over the table, which names the file and its unit.
    public var caption: String {
        let what = rows == .gene ? "genes" : "transcripts"
        let kind = column == .masked ? "Masked counts" : "Counts"
        return "\(kind) in \(unitWords) from \(path), \(rowCount) \(what) by \(sampleIDs.count) samples. "
            + "Name, biotype and not host are as genes.tsv lists them."
    }
}

/// The quality numbers and the sample correlation, as `rnaseq quality` prints them.
public struct RNASeqBulkQuality: Equatable, Sendable {
    public var summary: RNASeqQualitySummary
    public var correlation: RNASeqSampleCorrelation
    /// What `rnaseq quality --table samples` prints, with the same columns and cells.
    public var samples: RNASeqQualityDocument
    /// What `rnaseq quality --table correlation` prints.
    public var correlationTable: RNASeqQualityDocument

    public init(summary: RNASeqQualitySummary, correlation: RNASeqSampleCorrelation) {
        self.summary = summary
        self.correlation = correlation
        self.samples = summary.document()
        self.correlationTable = correlation.document()
    }

    /// The column titles the quality table shows, in the order of the CLI's columns. The CLI's own name of each column
    /// is in its tooltip.
    public static let columnTitles: [String: String] = [
        "sample_id": "Sample", "library_size": "Library size", "library_size_source": "Library size from",
        "mapping_rate_percent": "Mapping rate (%)", "library_type": "Library type", "counted": "Counted",
        "rrna_percent": "On rRNA genes (%)", "not_host_percent": "Not host (%)", "globin_percent": "On globin genes (%)",
    ]

    /// The lines under the quality table, the rule of each share as the CLI's record states it.
    public var notes: [String] {
        ["rRNA", "notHost", "globin"].compactMap { key in samples.facts[key].map { "\(Self.noteLabels[key] ?? key): \($0)." } }
    }

    static let noteLabels = ["rRNA": "rRNA genes", "notHost": "Not host", "globin": "Globin genes"]
}

/// Where the quality view stands. A refusal holds the words of `rnaseq quality`.
public enum RNASeqBulkQualityState: Equatable, Sendable {
    case loading
    case loaded(RNASeqBulkQuality)
    case failed(String)
}

/// The state of the bulk view, injected into ``RNASeqBulkViewController``. A test reads every cell from here with no window.
@MainActor
@Observable
public final class RNASeqBulkModel {
    public private(set) var name = ""
    public private(set) var bundleURL: URL?
    public private(set) var tables: [RNASeqBulkTable] = []
    public private(set) var genes: [RNASeqGeneRecord] = []
    public private(set) var searchText = ""
    public private(set) var quality: RNASeqBulkQualityState = .loading
    /// How many results this model has shown, so a view builds its tabs again for a new one.
    public private(set) var showCount = 0

    /// The titles of the three columns of `genes.tsv` that sit beside the feature id.
    public static let geneColumnTitles = ["Name", "Biotype", "Not host"]
    public static var notRecordedText: String { RNASeqResultBundle.notRecordedText }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var qualityTask: Task<Void, Never>?

    public nonisolated init() {}

    /// Shows a result the surface read. The count tables are shown at once, and the quality numbers are read off the
    /// main actor through the checks of `rnaseq quality`, once for each show.
    public func show(result: RNASeqResult, bundleURL: URL) {
        generation += 1
        showCount = generation
        let mine = generation
        name = result.manifest.name
        self.bundleURL = bundleURL
        genes = result.genes
        var lineOfGene: [String: Int] = [:]
        for (line, gene) in result.genes.enumerated() where lineOfGene[gene.id] == nil { lineOfGene[gene.id] = line }
        tables = result.counts.map { count in
            let lines = count.table.rows.map { lineOfGene[$0.id] ?? -1 }
            let keys = zip(count.table.rows, lines).map { row, line in
                (row.id + "\t" + (line >= 0 ? result.genes[line].name ?? "" : "")).lowercased()
            }
            return RNASeqBulkTable(
                path: count.entry.path, rows: count.entry.rows, column: count.entry.column, unit: count.entry.unit,
                table: count.table, visibleRows: Array(count.table.rows.indices), geneLine: lines, searchKeys: keys)
        }
        searchText = ""
        quality = .loading
        qualityTask?.cancel()
        qualityTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { RNASeqBulkModel.readQuality(bundleURL) }.value
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            self.quality = outcome
        }
    }

    /// Returns when the quality numbers of the last show are read.
    public func qualityRead() async {
        await qualityTask?.value
    }

    /// Keeps the rows whose feature id or gene name holds `text`, in any case. Empty text keeps every row.
    public func search(_ text: String) {
        searchText = text
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var shown = tables
        for index in shown.indices {
            let keys = shown[index].searchKeys
            shown[index].visibleRows = query.isEmpty ? Array(keys.indices) : keys.indices.filter { keys[$0].contains(query) }
        }
        tables = shown
    }

    // MARK: - Cells

    /// The cells of one row as the file prints them, the feature id and then one count a sample.
    public func countCells(table: Int, row: Int) -> [String] {
        let line = tables[table].table.rows[row]
        return [line.id] + line.counts.map(Self.countText)
    }

    /// The name, biotype and not-host flag that `genes.tsv` gives the row, each Not recorded where the file is empty.
    public func geneCells(table: Int, row: Int) -> [String] {
        let line = tables[table].geneLine[row]
        guard line >= 0 else { return Array(repeating: Self.notRecordedText, count: Self.geneColumnTitles.count) }
        let gene = genes[line]
        return [gene.name ?? Self.notRecordedText, gene.biotype ?? Self.notRecordedText,
                gene.notHost.map { $0 ? "true" : "false" } ?? Self.notRecordedText]
    }

    /// The cells the table shows for a row, in the order of its columns: the feature id, the three gene columns, then
    /// the counts.
    public func shownCells(table: Int, row: Int) -> [String] {
        let counts = countCells(table: table, row: row)
        return [counts[0]] + geneCells(table: table, row: row) + counts.dropFirst()
    }

    /// One cell of ``shownCells(table:row:)``, printed alone so a table prints only the cells it draws.
    public func shownCell(table: Int, row: Int, column: Int) -> String {
        let line = tables[table].table.rows[row]
        switch column {
        case 0: return line.id
        case 1...Self.geneColumnTitles.count: return geneCells(table: table, row: row)[column - 1]
        default: return Self.countText(line.counts[column - 1 - Self.geneColumnTitles.count])
        }
    }

    /// The titles of the table's columns, the feature, the gene columns and the sample ids.
    public func columnTitles(table: Int) -> [String] {
        [tables[table].rows == .gene ? "Gene" : "Transcript"] + Self.geneColumnTitles + tables[table].sampleIDs
    }

    /// A count as the one writer prints it (`RNASeqTSV.number` in LungfishIO), a whole count as an integer and any other
    /// as Swift's shortest text, so a cell reads as the file holds it.
    public nonisolated static func countText(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
    }

    /// Reads the quality numbers as `rnaseq quality` does: the result's checks once, then both tables from that read.
    public nonisolated static func readQuality(_ bundleURL: URL) -> RNASeqBulkQualityState {
        do {
            let result = try RNASeqQualitySummary.loadVerified(bundleURL)
            let label = bundleURL.lastPathComponent
            return .loaded(RNASeqBulkQuality(
                summary: try RNASeqQualitySummary(result: result, label: label),
                correlation: try RNASeqSampleCorrelation(result: result, label: label)))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
