// TaxTriageExportLoader.swift - What the TaxTriage organism matrix and batch report exports read from a result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The TaxTriage organism matrix export (Phase 2.12 lane 12.32, ARCH ruling X-1 row A4).
///
/// The viewer and `taxtriage export organism-matrix` build their invocation with this enum, so the Operations row, the
/// runner and the leaf's record name one command (ARCH 2).
public enum TaxTriageOrganismMatrixExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["taxtriage", "export", "organism-matrix"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish taxtriage export organism-matrix"

    /// The leaf's invocation for a view state, with absolute standardized paths. `samples` names the ticked samples
    /// as the result records them and `searchText` the organism search, which are the two view states the matrix
    /// bytes follow (the flat table's sort and column filters never reach them).
    public static func invocation(
        resultURL: URL,
        samples: [String],
        searchText: String?,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        TaxTriageExportLoader.invocation(
            commandPath: commandPath,
            resultURL: resultURL,
            samples: samples,
            searchText: searchText,
            outputURL: outputURL,
            force: force,
            emitsEvents: emitsEvents
        )
    }
}

/// The TaxTriage batch report export (Phase 2.12 lane 12.32, ARCH ruling X-1 row A5).
public enum TaxTriageBatchReportExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["taxtriage", "export", "batch-report"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish taxtriage export batch-report"

    /// The leaf's invocation for a view state, with absolute standardized paths.
    public static func invocation(
        resultURL: URL,
        samples: [String],
        searchText: String?,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        TaxTriageExportLoader.invocation(
            commandPath: commandPath,
            resultURL: resultURL,
            samples: samples,
            searchText: searchText,
            outputURL: outputURL,
            force: force,
            emitsEvents: emitsEvents
        )
    }
}

/// The TaxTriage results export (Phase 2.12 lane 12.32, ARCH ruling X-1 row A6).
///
/// The viewer and `taxtriage export results` build their invocation with this enum, so the Operations row, the
/// runner and the leaf's record name one command (ARCH 2).
public enum TaxTriageResultsExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["taxtriage", "export", "results"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish taxtriage export results"

    /// The leaf's invocation for a view state, with absolute standardized paths. `samples` names the ticked samples
    /// as the result records them, `searchText` the organism search, `sortKeys` the flat table's sort descriptors,
    /// `filters` its column filters and `metadataColumns` the metadata columns it shows.
    public static func invocation(
        resultURL: URL,
        samples: [String],
        searchText: String?,
        sortKeys: [ViewerExportSortKey],
        filters: ColumnFilterSet,
        metadataColumns: [String],
        format: ViewerExportDelimitedFormat,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: resultURL.standardizedFileURL.path,
            state: ViewerTableExportState(
                samples: samples,
                searchText: searchText,
                sortKeys: sortKeys,
                filters: filters,
                metadataColumns: metadataColumns
            ),
            outputFormat: format.rawValue,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }
}

/// What an export of a TaxTriage result reads, as the viewer holds it after it opens the result
/// (`TaxTriageResultViewController.configureFromDatabase`).
///
/// It is not `Sendable` because ``TaxTriageResult`` is not.
public struct TaxTriageExportSource {
    /// The result's `taxtriage.sqlite`.
    public let databaseURL: URL
    /// The run's `taxtriage-result.json`, nil when the result folder holds none.
    public let sidecarURL: URL?
    /// The run's sidecar, which holds the platform, runtime, exit code and the samples' negative-control marks.
    public let result: TaxTriageResult?
    /// Every sample of the database, sorted as the viewer sorts them.
    public let sampleIds: [String]
    /// The samples the metrics were read for, in ``sampleIds`` order.
    public let selectedSamples: [String]
    /// The metrics of the selected samples that match the search, in the database's order. This is the viewer's
    /// `allBatchGroupRows`.
    public let metrics: [TaxTriageMetric]

    /// The samples the run marks as negative controls, empty without a sidecar.
    public var negativeControlSampleIds: Set<String> {
        guard let config = result?.config else { return [] }
        return Set(config.samples.filter(\.isNegativeControl).map(\.sampleId))
    }

    /// The organisms the metrics name, counted case and edge-whitespace insensitively as the viewer counts them.
    public var crossSampleOrganismCount: Int {
        Set(metrics.map { $0.organism.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }).count
    }

    /// The files the export read, which a record names as inputs (BIO 6).
    public var inputURLs: [URL] {
        [databaseURL] + (sidecarURL.map { [$0] } ?? [])
    }
}

/// Reads a TaxTriage result folder for the organism matrix and the batch report, with the logic the viewer uses to
/// load the rows of its ticked samples and its organism search.
public enum TaxTriageExportLoader {
    /// The batch database of a result folder, which the viewer opens and the leaves read.
    public static let databaseFileName = "taxtriage.sqlite"
    /// The sidecar of the run, which the viewer loads for the negative controls and the run facts.
    public static let sidecarFileName = "taxtriage-result.json"
    /// Every production TaxTriage result opens through `configureFromDatabase`, so every record holds this mode and
    /// no leaf takes `--mode` (BIO ruling on 12.32, F1).
    public static let tableModeName = "batchGroup"
    /// The viewer reads its rows in pages of this size.
    static let pageSize = 500

    /// A failure to read the result, which a leaf reports as a refusal.
    public enum LoadError: Error, LocalizedError, Equatable {
        case unreadableDatabase(path: String, detail: String)
        case unknownSamples(names: [String], databasePath: String)
        case unreadableSidecar(path: String, detail: String)

        public var errorDescription: String? {
            switch self {
            case .unreadableDatabase(let path, let detail):
                return "The TaxTriage database at \(path) cannot be read. \(detail)"
            case .unknownSamples(let names, let databasePath):
                return "No sample \(names.joined(separator: ", ")) in \(databasePath). "
                    + "Pass --sample with an id the result records."
            case .unreadableSidecar(let path, let detail):
                return "The run's sidecar at \(path) cannot be read. \(detail)"
            }
        }
    }

    /// The leaf invocation both exports share.
    static func invocation(
        commandPath: [String],
        resultURL: URL,
        samples: [String],
        searchText: String?,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: resultURL.standardizedFileURL.path,
            state: ViewerTableExportState(samples: samples, searchText: searchText),
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The metric the viewer builds from a database row (`makeTaxTriageDatabasePageSnapshot`).
    public static func metric(from row: TaxTriageTaxonomyRow) -> TaxTriageMetric {
        TaxTriageMetric(
            sample: row.sample,
            taxId: row.taxId,
            organism: row.organism,
            reads: row.readsAligned,
            abundance: row.pctReads,
            coverageBreadth: row.coverageBreadth,
            coverageDepth: row.meanDepth,
            tassScore: row.tassScore,
            confidence: row.confidence
        )
    }

    /// Reads the result folder for `samples` (every sample when empty) and the organism `searchText`.
    ///
    /// The metrics are the rows the viewer holds after it loads the same samples and search, in the database's
    /// order. The sidecar is optional because the viewer shows a result without it, and a sidecar that exists must
    /// decode.
    ///
    /// - Throws: ``LoadError`` for a database that cannot be read, a sample the database does not hold or a sidecar
    ///   that does not decode.
    public static func load(resultURL: URL, samples: [String], searchText: String?) throws -> TaxTriageExportSource {
        let databaseURL = resultURL.appendingPathComponent(databaseFileName)
        let database: TaxTriageDatabase
        let sampleIds: [String]
        do {
            database = try TaxTriageDatabase(at: databaseURL)
            sampleIds = try database.fetchSamples().map(\.sample).sorted()
        } catch {
            throw LoadError.unreadableDatabase(path: databaseURL.path, detail: "\(error)")
        }
        let unknown = samples.filter { !sampleIds.contains($0) }
        guard unknown.isEmpty else {
            throw LoadError.unknownSamples(names: unknown, databasePath: databaseURL.path)
        }
        let requested = Set(samples)
        let selected = samples.isEmpty ? sampleIds : sampleIds.filter { requested.contains($0) }

        var rows: [TaxTriageTaxonomyRow] = []
        var offset = 0
        do {
            while true {
                try Task.checkCancellation()
                let page = try database.fetchRowsPage(
                    samples: selected,
                    limit: pageSize,
                    offset: offset,
                    organismSearchText: searchText
                )
                rows.append(contentsOf: page.rows)
                offset += page.rows.count
                if page.rows.isEmpty || rows.count >= page.totalMatchingRows { break }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LoadError.unreadableDatabase(path: databaseURL.path, detail: "\(error)")
        }

        let sidecarURL = resultURL.appendingPathComponent(sidecarFileName)
        var result: TaxTriageResult?
        var sidecar: URL?
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            sidecar = sidecarURL
            do {
                result = try TaxTriageResult.load(from: resultURL)
            } catch {
                throw LoadError.unreadableSidecar(path: sidecarURL.path, detail: "\(error)")
            }
        }
        return TaxTriageExportSource(
            databaseURL: databaseURL,
            sidecarURL: sidecar,
            result: result,
            sampleIds: sampleIds,
            selectedSamples: selected,
            metrics: rows.map(metric(from:))
        )
    }
}
