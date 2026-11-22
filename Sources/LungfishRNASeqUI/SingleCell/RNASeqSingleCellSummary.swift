// RNASeqSingleCellSummary.swift - What the single-cell view shows, read from the result as the CLI wrote it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Every number here is a value of `cells.sqlite`, of the manifest or of the quality table, or a count that SQLite made
// in `RNASeqCellsDatabase+Bins.swift`. Nothing on screen is computed (`docs/plans/2026-10-02-architecture-program.md:262`),
// and `cells.sqlite` opens read only, so reading never writes into the result (`docs/formats/rnaseq-bundle.md`).

import Foundation
import LungfishIO

/// The words the single-cell view shows. None of them judges a cell (prog:113), and the flag words come from
/// `not_host_calls.flag` as the file holds them.
public enum RNASeqSingleCellWords {
    /// What the rank plot's info button opens. It is true of every single-cell result, so it is general (5.6 U1).
    public static let rankPlot = "The plot ranks the cells of cells.sqlite by UMIs, most first. The result keeps no raw barcode list, so barcodes outside the cells are not in the plot."
    /// The help tag of that button.
    public static let rankPlotSummary = "The plot ranks the cells of cells.sqlite by UMIs, most first."
    /// What the button explains, the "<thing>" of its VoiceOver label "About <thing>".
    public static let rankPlotSubject = "the rank plot"
    public static let noNotHost = "This result holds no not-host counts. To count them, import the folder again with a reference set and a not-host BAM for each sample."
    public static let noCellsSummary = "This result names no cells.sqlite, so no cell summary shows. Import the Cell Ranger or STARsolo folder again to write one."
    public static let noQuality = "The result keeps no quality table, so quality reads \(RNASeqResultBundle.notRecordedText)."
    public static let noCells = "The result holds no cells, so there is nothing to plot. Check that the run found cells, then import its folder again."
    /// The step after a read that failed. A newer schema's own words name theirs.
    public static let tryAgain = "Check that the result folder is whole, or import it again."
    /// The words of a masked column that the file holds none for, as the CLI says them. A virus or a spike-in has no rRNA to mask.
    public static let noMask = "No rRNA mask, none needed"
    /// The one line in view that names the route to place these cells on an embedding, so the route stays where a person
    /// looks (UX OBJECT U5, walk row B3).
    public static let cellMap = "To see these cells on an embedding, use Import Embedding…"
    /// What the info button after that line opens, the command line routes. Each writes a new cell map beside the result.
    public static let cellMapRoutes = "Or run lungfish-cli rnaseq cell-map import or lungfish-cli rnaseq cell-map compute on this result. Either writes a new cell map result and leaves this one as it is."
    /// The help tag of that button.
    public static let cellMapSummary = "Either writes a new cell map result and leaves this one as it is."
    public static let cellMapSubject = "importing an embedding"
}

/// The summary of a single-cell result. Its parts are values as written or counts that SQLite made.
public struct RNASeqSingleCellSummary: Equatable, Sendable {
    /// One histogram, with the bins `RNASeqCellsDatabase.bins(of:inFileAt:)` read.
    public struct Histogram: Equatable, Sendable {
        /// `umis`, `genes` or `not-host-<extra number>`, the end of the view's accessibility id.
        public var id: String
        public var title: String
        public var bins: [RNASeqCellsDatabase.Bin]
    }

    /// Each row of `samples`, with its cells, features and entries.
    public var samples: [RNASeqCellsDatabase.Sample]
    /// The tool and version of the manifest's `origin`, each Not recorded when the manifest names none.
    public var tool: String
    public var toolVersion: String
    /// The quality table as written, or nil when the result keeps none.
    public var quality: RNASeqQualityTable?
    /// `SELECT count(*) FROM cells`.
    public var cellCount: Int
    public var rankSteps: [RNASeqCellsDatabase.RankStep]
    public var umis: Histogram
    public var genes: Histogram
    /// One histogram for each not-host extra, none when the result holds no not-host table.
    public var notHost: [Histogram]
    public var extras: [RNASeqCellsDatabase.NotHostExtra]

    /// The histograms in the order the view shows them.
    public var histograms: [Histogram] { [umis, genes] + notHost }
}

/// What reading the summary gave. It holds no state of the main actor, so a detached task can return it.
public enum RNASeqSingleCellLoadOutcome: Equatable, Sendable {
    case loaded(RNASeqSingleCellSummary, cellsURL: URL)
    /// The reader's words, such as those of a `cells.sqlite` of a newer schema (`docs/formats/rnaseq-bundle.md:244`).
    case failed(String)
}

extension RNASeqSingleCellSummary {
    /// The `cells.sqlite` the manifest names, inside the result.
    public static func cellsURL(of result: RNASeqResult, bundleURL: URL) throws -> URL? {
        guard let summary = result.manifest.cellsSummary else { return nil }
        return try RNASeqResultBundle.resolve(summary.path, in: bundleURL)
    }

    /// Reads the summary. It only reads, so a result is never changed by being shown.
    public nonisolated static func read(_ result: RNASeqResult, bundleURL: URL) -> RNASeqSingleCellLoadOutcome {
        do {
            guard let url = try cellsURL(of: result, bundleURL: bundleURL) else { return .failed(RNASeqSingleCellWords.noCellsSummary) }
            let database = try RNASeqCellsDatabase(url: url)
            let extras = try database.notHostExtras()
            let origin = result.manifest.origin
            let summary = RNASeqSingleCellSummary(
                samples: try database.samples(),
                tool: origin.tool ?? RNASeqResultBundle.notRecordedText,
                toolVersion: origin.toolVersion ?? RNASeqResultBundle.notRecordedText,
                quality: result.quality,
                cellCount: try database.cellCount(),
                rankSteps: try RNASeqCellsDatabase.rankSteps(inFileAt: url),
                umis: Histogram(id: "umis", title: "UMIs per cell", bins: try RNASeqCellsDatabase.bins(of: .umis, inFileAt: url)),
                genes: Histogram(id: "genes", title: "Genes per cell", bins: try RNASeqCellsDatabase.bins(of: .genes, inFileAt: url)),
                notHost: try extras.map { extra in
                    Histogram(id: "not-host-\(extra.extra)", title: "Not-host UMIs per cell, \(extra.name), default column",
                              bins: try RNASeqCellsDatabase.bins(of: .notHostUMIs(extra: extra.extra), inFileAt: url))
                },
                extras: extras)
            return .loaded(summary, cellsURL: url)
        } catch {
            return .failed(failureWords(error))
        }
    }

    /// A newer schema's words already say what to do. Any other failure gets the next step.
    static func failureWords(_ error: Error) -> String {
        if let known = error as? RNASeqResultError, case .newerSchema = known { return known.localizedDescription }
        let words = error.localizedDescription
        return (words.hasSuffix(".") ? words : words + ".") + " " + RNASeqSingleCellWords.tryAgain
    }
}

/// One row of the cells table, the cell as `cells` holds it and its not-host columns for each extra.
public struct RNASeqSingleCellRow: Equatable, Sendable {
    public var cell: RNASeqCellsDatabase.Cell
    public var notHost: [RNASeqCellsDatabase.NotHostCellColumns]
}

/// The cells of `cells.sqlite`, read a page at a time over a read-only handle that closes with this object.
public final class RNASeqSingleCellPages {
    public static let pageSize = 200
    /// The most pages kept at once, so scrolling half a million cells holds a few pages and not the table.
    static let keptPages = 8

    public let cellsURL: URL
    public let count: Int
    private var database: RNASeqCellsDatabase?
    private var pages: [Int: [RNASeqSingleCellRow]] = [:]

    public init(cellsURL: URL) throws {
        let database = try RNASeqCellsDatabase(url: cellsURL)
        self.cellsURL = cellsURL
        self.count = try database.cellCount()
        self.database = database
    }

    /// The page that starts at cell row `index * pageSize`, as `cells(offset:limit:)` gives it.
    public func page(_ index: Int) throws -> [RNASeqSingleCellRow] {
        if let kept = pages[index] { return kept }
        guard let database else { throw RNASeqResultError.unreadableFile(path: RNASeqCellsDatabase.filename, reason: "it is closed") }
        let offset = index * Self.pageSize
        let cells = try database.cells(offset: offset, limit: Self.pageSize)
        let columns = Dictionary(grouping: try RNASeqCellsDatabase.notHostColumns(offset: offset, limit: Self.pageSize, inFileAt: cellsURL), by: \.cell)
        let rows = cells.map { RNASeqSingleCellRow(cell: $0, notHost: columns[$0.cell] ?? []) }
        if pages.count >= Self.keptPages { pages.removeAll() }
        pages[index] = rows
        return rows
    }

    /// Row `row` of the table, or nil when it lies past the cells or the read failed.
    public func row(_ row: Int) -> RNASeqSingleCellRow? {
        guard row >= 0, row < count, let page = try? page(row / Self.pageSize) else { return nil }
        let index = row % Self.pageSize
        return index < page.count ? page[index] : nil
    }

    /// Closes the handle. A later read throws.
    public func close() {
        database = nil
        pages.removeAll()
    }
}
